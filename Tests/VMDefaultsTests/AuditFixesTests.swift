//
//  AuditFixesTests.swift
//  VMDefaults
//
//  Tests covering the 2026-06 audit fixes:
//    1. _readRaw returns non-nil defaults for Optional-typed keys (missing key,
//       stored value, and type-mismatched stored value), plus Double?/String?
//       round-trips through the generic path.
//    4. DefaultsKey/CodableDefaultsKey are conditionally Sendable.
//    5. KVO-based observation: per-key isolation, same-suite cross-instance
//       observation, and other-suite isolation.
//    6. with(container:) rebinds a key to a different UserDefaults container.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Fix 1: Optional-typed keys with non-nil defaults

@Suite("Audit Fix 1 – Optional keys honor non-nil defaults")
struct OptionalDefaultTests {

    @Test("Missing key returns non-nil default")
    @MainActor
    func missingKeyReturnsNonNilDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-nonnil-default", default: 7, container: defaults)

        #expect(defaults.object(forKey: key.name) == nil)
        #expect(key.get() == 7)
    }

    @Test("Stored value wins over non-nil default")
    @MainActor
    func storedValueWinsOverDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-stored", default: 7, container: defaults)

        key.set(3)
        #expect(key.get() == 3)
    }

    @Test("Type-mismatched stored value falls back to non-nil default")
    @MainActor
    func typeMismatchFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-mismatch", default: 7, container: defaults)

        // Store a String where an Int? is expected.
        defaults.set("not an int", forKey: key.name)
        #expect(key.get() == 7)
    }

    @Test("set(nil) removes the key, so reads return the default again")
    @MainActor
    func setNilReturnsToDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-nil-reset", default: 7, container: defaults)

        key.set(3)
        #expect(key.get() == 3)
        key.set(nil)
        #expect(defaults.object(forKey: key.name) == nil)
        // With a non-nil default, removal reads back as the default.
        #expect(key.get() == 7)
    }

    @Test("publisher() initial value honors non-nil default for missing optional key")
    @MainActor
    func publisherInitialHonorsNonNilDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-pub-default", default: 7, container: defaults)

        var received: [Int?] = []
        let cancellable = key.publisher().sink { received.append($0) }
        #expect(received == [7])
        _ = cancellable
    }

    @Test("ObservableUserDefault honors non-nil default for missing optional key")
    @MainActor
    func observableHonorsNonNilDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int?>("opt-int-vm-default", default: 7, container: defaults)

        let vm = ObservableVM(key)
        #expect(vm.value == 7)
    }

    // MARK: Double? round-trips (P-9 gap: only Int? was covered)

    @Test("Double? round-trip: missing, stored, nil-reset, mismatch")
    @MainActor
    func doubleOptionalRoundTrip() {
        let defaults = makeIsolatedDefaults()
        let nilDefaultKey = DefaultsKey<Double?>("opt-double-nildef", default: nil, container: defaults)
        let nonNilDefaultKey = DefaultsKey<Double?>("opt-double-def", default: 1.5, container: defaults)

        #expect(nilDefaultKey.get() == nil)
        #expect(nonNilDefaultKey.get() == 1.5)

        nilDefaultKey.set(2.5)
        #expect(nilDefaultKey.get() == 2.5)
        #expect(defaults.object(forKey: nilDefaultKey.name) != nil)

        nilDefaultKey.set(nil)
        #expect(nilDefaultKey.get() == nil)
        #expect(defaults.object(forKey: nilDefaultKey.name) == nil)

        defaults.set("garbage", forKey: nonNilDefaultKey.name)
        #expect(nonNilDefaultKey.get() == 1.5)
    }

    @Test("String? round-trip: missing, stored, nil-reset, mismatch")
    @MainActor
    func stringOptionalRoundTrip() {
        let defaults = makeIsolatedDefaults()
        let nilDefaultKey = DefaultsKey<String?>("opt-string-nildef", default: nil, container: defaults)
        let nonNilDefaultKey = DefaultsKey<String?>("opt-string-def", default: "fallback", container: defaults)

        #expect(nilDefaultKey.get() == nil)
        #expect(nonNilDefaultKey.get() == "fallback")

        nilDefaultKey.set("hello")
        #expect(nilDefaultKey.get() == "hello")

        nilDefaultKey.set(nil)
        #expect(nilDefaultKey.get() == nil)
        #expect(defaults.object(forKey: nilDefaultKey.name) == nil)

        defaults.set(42, forKey: nonNilDefaultKey.name)
        #expect(nonNilDefaultKey.get() == "fallback")
    }
}

// MARK: - Fix 4: Conditional Sendable

@Suite("Audit Fix 4 – Keys are conditionally Sendable")
struct KeySendableTests {

    private func requiresSendable<T: Sendable>(_ value: T) -> T { value }

    @Test("DefaultsKey and CodableDefaultsKey satisfy Sendable when Value is Sendable")
    func keysSatisfySendable() async {
        struct S: Codable, Equatable, Sendable { var v: Int }

        let raw = DefaultsKey<Int?>("sendable-raw", default: nil)
        let codable = CodableDefaultsKey<S>("sendable-codable", default: .init(v: 0))

        _ = requiresSendable(raw)
        _ = requiresSendable(codable)

        // Cross an isolation boundary with a key (would not compile without Sendable).
        let name = await Task.detached { raw.name }.value
        #expect(name == "sendable-raw")
    }
}

// MARK: - Fix 5: KVO-based per-key observation

@Suite("Audit Fix 5 – KVO observation scope")
struct KVOObservationScopeTests {

    @Test("Writing key B does not emit on key A's publisher")
    @MainActor
    func perKeyIsolationPublisher() async {
        let defaults = makeIsolatedDefaults()
        let keyA = DefaultsKey<Int>("kvo-iso-a", default: 0, container: defaults)
        let keyB = DefaultsKey<Int>("kvo-iso-b", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = keyA.publisher().sink { received.append($0) }
        #expect(received == [0])

        keyB.set(99)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        #expect(received == [0], "key A's publisher must not wake for key B writes")

        // Sanity: key A writes still emit.
        keyA.set(1)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)
        #expect(received == [0, 1])

        _ = cancellable
    }

    @Test("Writing key B does not yield on key A's updates() stream")
    @MainActor
    func perKeyIsolationAsyncStream() async {
        let defaults = makeIsolatedDefaults()
        let keyA = DefaultsKey<Int>("kvo-iso-stream-a", default: 0, container: defaults)
        let keyB = DefaultsKey<Int>("kvo-iso-stream-b", default: 0, container: defaults)

        var values: [Int] = []
        let collector = Task { @MainActor in
            var iterator = keyA.updates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 2 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        keyB.set(99)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)
        #expect(values == [0], "key A's stream must not wake for key B writes")

        keyA.set(1)
        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [0, 1])
    }

    @Test("Raw publisher observes writes from another instance of the same suite")
    @MainActor
    func publisherObservesOtherInstanceSameSuite() async {
        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)!
        let key = DefaultsKey<Int>("kvo-cross-instance-pub", default: 0, container: defaultsA)

        var received: [Int] = []
        let cancellable = key.publisher().sink { received.append($0) }
        #expect(received == [0])

        defaultsB.set(5, forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        #expect(received == [0, 5])
        _ = cancellable
    }

    @Test("ObservableUserDefault observes writes from another instance of the same suite")
    @MainActor
    func observableObservesOtherInstanceSameSuite() async {
        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)!
        let key = DefaultsKey<Int>("kvo-cross-instance-vm", default: 0, container: defaultsA)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaultsB.set(11, forKey: key.name)

        #expect(await waiter.value)
        #expect(vm.value == 11)
    }

    @Test("ObservableUserDefault does not fire objectWillChange for unrelated key writes")
    @MainActor
    func observableIgnoresUnrelatedKeyWrites() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("kvo-vm-isolated", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm, timeoutNanoseconds: 300_000_000)
        await yieldForSubscriptionInstall()

        defaults.set("noise", forKey: "kvo-vm-unrelated")

        #expect(await waiter.value == false, "unrelated key writes must not wake the wrapper")
        #expect(vm.value == 0)
    }

    @Test("Same key name in a different suite is not observed")
    @MainActor
    func otherSuiteIsNotObserved() async {
        let defaultsA = makeIsolatedDefaults()
        let defaultsB = makeIsolatedDefaults() // different suite
        let key = DefaultsKey<Int>("kvo-other-suite", default: 0, container: defaultsA)

        var received: [Int] = []
        let cancellable = key.publisher().sink { received.append($0) }
        #expect(received == [0])

        defaultsB.set(1, forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        #expect(received == [0])
        _ = cancellable
    }
}

// MARK: - Fix 6: with(container:)

@Suite("Audit Fix 6 – with(container:) rebinding")
struct WithContainerTests {

    @Test("Rebinding preserves name and default, and isolates storage")
    @MainActor
    func rawKeyRebindIsolatesStorage() {
        let defaultsA = makeIsolatedDefaults()
        let defaultsB = makeIsolatedDefaults()
        let original = DefaultsKey<Int?>("rebind-raw", default: 7, container: defaultsA)
        let rebound = original.with(container: defaultsB)

        #expect(rebound.name == original.name)
        #expect(rebound.defaultValue == original.defaultValue)
        #expect(rebound.container === defaultsB)
        #expect(original.container === defaultsA)

        rebound.set(1)
        #expect(rebound.get() == 1)
        #expect(original.get() == 7, "write through the rebound key must not leak into the original container")

        original.set(2)
        #expect(original.get() == 2)
        #expect(rebound.get() == 1)
    }

    @Test("CodableDefaultsKey rebinding preserves name and default, and isolates storage")
    @MainActor
    func codableKeyRebindIsolatesStorage() {
        struct S: Codable, Equatable, Sendable { var v: Int }
        let defaultsA = makeIsolatedDefaults()
        let defaultsB = makeIsolatedDefaults()
        let original = CodableDefaultsKey<S>("rebind-codable", default: .init(v: 0), container: defaultsA)
        let rebound = original.with(container: defaultsB)

        #expect(rebound.name == original.name)
        #expect(rebound.defaultValue == original.defaultValue)
        #expect(rebound.container === defaultsB)

        rebound.set(.init(v: 1))
        #expect(rebound.get() == .init(v: 1))
        #expect(original.get() == .init(v: 0))
    }

    @Test("Rebound key works with ObservableUserDefault")
    @MainActor
    func reboundKeyDrivesObservableUserDefault() async {
        let isolated = makeIsolatedDefaults()
        // Key nominally defined against .standard, rebound to an isolated suite —
        // the intended test-injection pattern for consumers.
        let key = DefaultsKey<Int>("rebind-vm", default: 0).with(container: isolated)
        let vm = ObservableVM(key)

        vm.value = 9
        #expect(isolated.integer(forKey: key.name) == 9)
        #expect(UserDefaults.standard.object(forKey: key.name) == nil)
    }
}
