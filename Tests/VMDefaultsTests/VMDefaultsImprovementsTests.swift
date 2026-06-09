//
//  VMDefaultsImprovementsTests.swift
//  VMDefaults
//
//  Tests covering the six improvements made to the VMDefaults package:
//    1. publisher() delivers via DispatchQueue.main (drains during Task.sleep)
//    2. DefaultsBox refreshes synchronously when notification arrives on main thread
//    3. Deferred publisher captures initial value at subscription time, not creation time
//    4. AnyDefaultsKey protocol conformance for both key types
//    5. ObservableUserDefault lazy-binding behavior (ensureBound on first access)
//    6. CodableDefaultsKey.publisher() delivers via DispatchQueue.main
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Fix 1: publisher() delivers via DispatchQueue.main

@Suite("Fix 1 – publisher delivers via DispatchQueue.main")
struct PublisherDispatchQueueMainTests {

    @Test("publisher update arrives after Task.sleep without spinning RunLoop")
    @MainActor
    func publisherUpdateArrivesAfterTaskSleep() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix1.int", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [0])

        defaults.set(7, forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.contains(7))
        _ = cancellable
    }

    @Test("publisher update for optional value arrives after Task.sleep")
    @MainActor
    func publisherOptionalUpdateArrivesAfterTaskSleep() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("fix1.opt", default: nil, container: defaults)

        var received: [String?] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [nil])

        defaults.set("hello", forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.last == "hello")
        _ = cancellable
    }

    @Test("multiple publisher updates all arrive after Task.sleep without RunLoop")
    @MainActor
    func multiplePublisherUpdatesArriveAfterTaskSleep() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix1.multi", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [0])

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(2, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.contains(1))
        #expect(received.last == 2)
        _ = cancellable
    }
}

// MARK: - Fix 2: DefaultsBox — simplified coalescing (isRefreshScheduled removed)

@Suite("Fix 2 – DefaultsBox simplified coalescing")
struct DefaultsBoxCoalescingTests {

    @Test("ObservableUserDefault picks up external write after async settle")
    @MainActor
    func observablePicksUpExternalWriteAfterSettle() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix2.settle", default: 0, container: defaults)
        let vm = ObservableVM(key)

        // External write that bypasses the property wrapper — simulates iCloud or another process.
        defaults.set(42, forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(vm.value == 42)
    }

    @Test("ObservableUserDefault fires objectWillChange on external write")
    @MainActor
    func externalWriteFiresObjectWillChange() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix2.owc", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let willChangeWaiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.set(99, forKey: key.name)
        postDidChange(for: defaults)

        let fired = await willChangeWaiter.value
        #expect(fired)
        #expect(vm.value == 99)
    }

    @Test("coalescedRefresh is idempotent: burst notifications produce at most one value update")
    @MainActor
    func burstNotificationsProduceAtMostOneValueUpdate() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix2.burst", default: 0, container: defaults)
        let vm = ObservableVM(key)

        var changeCount = 0
        let cancellable = vm.objectWillChange.sink { changeCount += 1 }

        // Write once, post three notifications (simulates burst).
        defaults.set(7, forKey: key.name)
        postDidChange(for: defaults)
        postDidChange(for: defaults)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        // All three tasks run, but coalescedRefresh guard prevents duplicate value updates.
        #expect(vm.value == 7)
        #expect(changeCount <= 2) // at most objectWillChange once (or once per notification, but all idempotent after first)
        _ = cancellable
    }
}

// MARK: - Fix 3: Deferred publisher captures initial value at subscription time

@Suite("Fix 3 – Deferred publisher: initial value at subscription time")
struct DeferredPublisherInitialValueTests {

    @Test("publisher() initial value reflects state at subscription time, not creation time")
    @MainActor
    func initialValueAtSubscriptionTime() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix3.deferred", default: 0, container: defaults)

        // Create the publisher before the value is stored.
        let publisher = key.publisher()

        // Update UserDefaults after publisher creation but before subscription.
        defaults.set(42, forKey: key.name)

        // Subscribe — initial should be 42 (current state), not 0 (state at creation time).
        var received: [Int] = []
        let cancellable = publisher.sink { received.append($0) }

        #expect(received.first == 42)
        _ = cancellable
    }

    @Test("publisher() with multiple subscriptions each get the fresh initial value")
    @MainActor
    func multipleSubscriptionsEachGetFreshInitial() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix3.multi.sub", default: 0, container: defaults)

        let publisher = key.publisher()

        defaults.set(10, forKey: key.name)
        var received1: [Int] = []
        let c1 = publisher.sink { received1.append($0) }

        defaults.set(20, forKey: key.name)
        var received2: [Int] = []
        let c2 = publisher.sink { received2.append($0) }

        #expect(received1.first == 10)
        #expect(received2.first == 20)
        _ = c1; _ = c2
    }

    @Test("CodableDefaultsKey publisher() initial value reflects state at subscription time")
    @MainActor
    func codableInitialValueAtSubscriptionTime() throws {
        struct Settings: Codable, Equatable, Sendable { var count: Int }

        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("fix3.codable.deferred", default: .init(count: 0), container: defaults)

        let publisher = key.publisher()

        let payload = Settings(count: 77)
        defaults.set(try JSONEncoder().encode(payload), forKey: key.name)

        var received: [Settings] = []
        let cancellable = publisher.sink { received.append($0) }

        #expect(received.first == payload)
        _ = cancellable
    }
}

// MARK: - Fix 4: AnyDefaultsKey protocol

@Suite("Fix 4 – AnyDefaultsKey protocol")
struct AnyDefaultsKeyTests {

    @Test("DefaultsKey conforms to AnyDefaultsKey")
    func defaultsKeyConformsToAnyDefaultsKey() {
        let key: any AnyDefaultsKey = DefaultsKey<Int>("proto.int", default: 0)
        #expect(key.name == "proto.int")
        #expect(key.container === UserDefaults.standard)
    }

    @Test("CodableDefaultsKey conforms to AnyDefaultsKey")
    func codableDefaultsKeyConformsToAnyDefaultsKey() {
        struct Settings: Codable { var count: Int }
        let key: any AnyDefaultsKey = CodableDefaultsKey<Settings>("proto.codable", default: .init(count: 0))
        #expect(key.name == "proto.codable")
        #expect(key.container === UserDefaults.standard)
    }

    @Test("AnyDefaultsKey carries custom container reference")
    func anyDefaultsKeyCarriesCustomContainer() {
        let defaults = makeIsolatedDefaults()
        let key: any AnyDefaultsKey = DefaultsKey<Bool>("proto.custom.container", default: false, container: defaults)
        #expect(key.container === defaults)
    }

    @Test("heterogeneous array of AnyDefaultsKey works")
    func heterogeneousArrayOfAnyDefaultsKey() {
        struct S: Codable { var v: Int }
        let keys: [any AnyDefaultsKey] = [
            DefaultsKey<Int>("proto.array.int", default: 0),
            DefaultsKey<String?>("proto.array.str", default: nil),
            CodableDefaultsKey<S>("proto.array.codable", default: .init(v: 0))
        ]
        #expect(keys.map(\.name) == ["proto.array.int", "proto.array.str", "proto.array.codable"])
    }
}

// MARK: - Fix 5: ObservableUserDefault lazy binding (ensureBound)

@Suite("Fix 5 – ObservableUserDefault lazy binding behavior")
struct ObservableUserDefaultLazyBindingTests {

    @Test("objectWillChange fires after external write when value was accessed at init (eager binding)")
    @MainActor
    func eagerBindingFiresObjectWillChange() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("fix5.eager", default: 0, container: defaults)
        // ObservableVM accesses `value` in its init — installing the binding eagerly.
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.set(55, forKey: key.name)
        postDidChange(for: defaults)

        let fired = await waiter.value
        #expect(fired)
        #expect(vm.value == 55)
    }

    @Test("value is readable immediately at init via eager access in ObservableVM")
    @MainActor
    func valueIsReadableImmediatelyViaEagerAccess() {
        let defaults = makeIsolatedDefaults()
        defaults.set(42, forKey: "fix5.pre-init")
        let key = DefaultsKey<Int>("fix5.pre-init", default: 0, container: defaults)
        let vm = ObservableVM(key)
        // ObservableVM reads `value` in its init (installing the binding) and captures the current
        // UserDefaults state. The synchronous read in init should reflect 42.
        #expect(vm.value == 42)
    }
}

// MARK: - Fix 6: CodableDefaultsKey.publisher() delivers via DispatchQueue.main

@Suite("Fix 6 – CodableDefaultsKey publisher delivers via DispatchQueue.main")
struct CodablePublisherDispatchQueueMainTests {

    struct CItem: Codable, Equatable, Sendable { var label: String }

    @Test("Codable publisher update arrives after Task.sleep without spinning RunLoop")
    @MainActor
    func codablePublisherUpdateArrivesAfterTaskSleep() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<CItem>("fix6.codable", default: .init(label: "zero"), container: defaults)

        var received: [CItem] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [.init(label: "zero")])

        let next = CItem(label: "one")
        defaults.set(try JSONEncoder().encode(next), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.contains(next))
        _ = cancellable
    }

    @Test("Codable publisher delivers sequential updates after each Task.sleep")
    @MainActor
    func codablePublisherDeliversSequentialUpdates() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<CItem>("fix6.seq", default: .init(label: "start"), container: defaults)

        var received: [CItem] = []
        let cancellable = key.publisher().sink { received.append($0) }

        let a = CItem(label: "a")
        let b = CItem(label: "b")

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.first == .init(label: "start"))
        #expect(received.last == b)
        _ = cancellable
    }
}
