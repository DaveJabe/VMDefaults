//
//  VMDefaultsTests.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//
//  These tests validate two key promises of the package:
//
//  1) Local writes:
//     Assigning the wrapped property (e.g. `vm.value = ...`) should:
//       - persist to the provided UserDefaults container
//       - trigger `objectWillChange` so SwiftUI updates immediately
//
//  2) External writes:
//     Mutating the same UserDefaults key elsewhere (another VM/screen/process) should:
//       - update the wrapped property
//       - trigger `objectWillChange` in the observing VM
//
//  Notes:
//  - In real apps, `UserDefaults.didChangeNotification` is posted by the system.
//    In tests (especially with suite-based defaults), we explicitly post it to make
//    the external-write behavior deterministic.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Shared constants

/// Default timeout used when waiting for `objectWillChange`.
private let willChangeTimeoutNanos: UInt64 = 2_000_000_000

/// Small “give the runloop a chance” delay used in a couple of places after posting
/// lots of external writes. Keep this tiny; tests should remain fast.
private let propagationDelayNanos: UInt64 = 30_000_000 // 30ms

// MARK: - Test helpers (UserDefaults + notifications)

/// Creates an isolated UserDefaults suite for a single test.
///
/// Why:
/// - prevents cross-test contamination
/// - ensures we never accidentally read/write `.standard`
///
/// Note: suites are not automatically removed; that's fine for unit tests.
private func makeIsolatedDefaults() -> UserDefaults {
    let suite = "VMDefaultsTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

/// Posts a `UserDefaults.didChangeNotification` for a given container.
///
/// Why:
/// - simulates an "external write" (e.g., another screen/VM updated the same key)
/// - makes tests deterministic across environments
private func postDidChange(for defaults: UserDefaults) {
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
}

// MARK: - Test helpers (waiting for objectWillChange)

/// File-scope gate to avoid Swift's "nested type in generic function" restriction.
private final class _WillChangeGate {
    var didResume = false
    var cancellable: AnyCancellable?
}

/// Waits for the next `objectWillChange` emission or times out.
///
/// Swift 6 considerations:
/// - Avoid task groups to sidestep "sending parameter" / @Sendable diagnostics.
/// - Keep the subscription + timeout scheduling on the main actor/runloop.
@MainActor
private func waitForObjectWillChange(
    _ object: some ObservableObject,
    timeoutNanoseconds: UInt64 = willChangeTimeoutNanos
) async -> Bool {
    let gate = _WillChangeGate()

    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let resume: (Bool) -> Void = { value in
            guard !gate.didResume else { return }
            gate.didResume = true
            gate.cancellable?.cancel()
            continuation.resume(returning: value)
        }

        // Subscribe to the next willChange emission.
        gate.cancellable = object.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in resume(true) }

        // Timeout path (also on main actor).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            resume(false)
        }
    }
}

/// Convenience to start waiting *before* triggering an event (avoids races).
@MainActor
private func startWillChangeWaiter(
    _ object: some ObservableObject,
    timeoutNanoseconds: UInt64 = willChangeTimeoutNanos
) -> Task<Bool, Never> {
    Task { @MainActor in
        await waitForObjectWillChange(object, timeoutNanoseconds: timeoutNanoseconds)
    }
}

/// Cheap “yield” to let the waiter subscription install before we trigger an event.
/// (Avoids arbitrary sleeps that slow down the test suite.)
@MainActor
private func yieldForSubscriptionInstall() async {
    await Task.yield()
}

// MARK: - Generic test view models

/// Minimal `ObservableObject` used to test `@ObservableUserDefault` across many `Value` types.
///
/// Important: the wrapper binds lazily on first property access. The `_ = self.value` line
/// forces that binding to install during init so tests don't have to remember it.
@MainActor
private final class ObservableVM<Value: Equatable & Sendable & PropertyListValue>: ObservableObject {
    @ObservableUserDefault var value: Value

    init(_ key: DefaultsKey<Value>) {
        _value = ObservableUserDefault(key)
        _ = value // installs the wrapper's forwarding subscription eagerly
    }
}

/// Minimal `ObservableObject` used to test `@CodableUserDefault`.
@MainActor
private final class CodableVM<Value: Codable & Equatable & Sendable>: ObservableObject {
    @ObservableUserDefault var value: Value

    init(_ key: CodableDefaultsKey<Value>) {
        _value = ObservableUserDefault(key)
        _ = value // installs the wrapper's forwarding subscription eagerly
    }
}

// MARK: - ObservableUserDefault tests

@Suite("VMDefaults - ObservableUserDefault")
struct ObservableUserDefaultTests {

    @Test("Default value when missing")
    @MainActor
    func defaultValueWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)

        let vm = ObservableVM(key)

        // With no stored value, the wrapper should surface the default and not write anything.
        #expect(vm.value == nil)
        #expect(defaults.object(forKey: key.name) == nil)
    }

    @Test("Local write publishes and persists")
    @MainActor
    func localWritePublishesAndPersists() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        vm.value = "ABC"

        #expect(await waiter.value, "Timed out waiting for objectWillChange after local write")
        #expect(vm.value == "ABC")
        #expect(defaults.string(forKey: key.name) == "ABC")
    }

    @Test("External write publishes and updates")
    @MainActor
    func externalWritePublishesAndUpdates() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        // External write: this simulates another VM/screen updating the same defaults key.
        defaults.set("XYZ", forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timed out waiting for objectWillChange after external write")
        #expect(vm.value == "XYZ")
    }

    @Test("Optional nil removes key")
    @MainActor
    func optionalNilRemovesKey() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        vm.value = "AAA"
        #expect(defaults.string(forKey: key.name) == "AAA")

        // Canonical UserDefaults behavior: setting Optional(nil) should remove the key.
        vm.value = nil
        #expect(defaults.object(forKey: key.name) == nil)
        #expect(vm.value == nil)
    }

    @Test("Multiple VMs stay in sync")
    @MainActor
    func multipleVMsStayInSync() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("shared", default: nil, container: defaults)

        let a = ObservableVM(key)
        let b = ObservableVM(key)

        let waiter = startWillChangeWaiter(b)
        await yieldForSubscriptionInstall()

        // Local write in `a` becomes an external write from `b`'s perspective.
        a.value = "SYNC"

        #expect(await waiter.value, "Timed out waiting for objectWillChange in peer VM")
        #expect(b.value == "SYNC")
    }

    @Test("Primitive round-trips: Int, Bool, Double")
    @MainActor
    func primitivesRoundTrip() async {
        let defaults = makeIsolatedDefaults()

        let intKey = DefaultsKey<Int>("int", default: 0, container: defaults)
        let boolKey = DefaultsKey<Bool>("bool", default: false, container: defaults)
        let doubleKey = DefaultsKey<Double>("double", default: 0.0, container: defaults)

        let intVM = ObservableVM(intKey)
        let boolVM = ObservableVM(boolKey)
        let doubleVM = ObservableVM(doubleKey)

        // Defaults should be surfaced before any write.
        #expect(intVM.value == 0)
        #expect(boolVM.value == false)
        #expect(doubleVM.value == 0.0)

        // Local writes should persist immediately.
        intVM.value = 42
        boolVM.value = true
        doubleVM.value = 3.14159

        #expect(defaults.integer(forKey: intKey.name) == 42)
        #expect(defaults.bool(forKey: boolKey.name) == true)
        #expect(abs(defaults.double(forKey: doubleKey.name) - 3.14159) < 1e-9)

        // External writes should propagate back into the VMs.
        let intWait = startWillChangeWaiter(intVM)
        let boolWait = startWillChangeWaiter(boolVM)
        let doubleWait = startWillChangeWaiter(doubleVM)
        await yieldForSubscriptionInstall()

        defaults.set(7, forKey: intKey.name)
        defaults.set(false, forKey: boolKey.name)
        defaults.set(2.71828, forKey: doubleKey.name)
        postDidChange(for: defaults)

        #expect(await intWait.value, "Timeout waiting for int update")
        #expect(await boolWait.value, "Timeout waiting for bool update")
        #expect(await doubleWait.value, "Timeout waiting for double update")

        #expect(intVM.value == 7)
        #expect(boolVM.value == false)
        #expect(abs(doubleVM.value - 2.71828) < 1e-9)
    }

    @Test("Uses provided container, not standard")
    @MainActor
    func usesProvidedContainerNotStandard() {
        // This test ensures we *only* read from the container provided to DefaultsKey,
        // not from UserDefaults.standard (a common foot-gun when keys are reused).
        let isolated = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("isolation", default: nil, container: isolated)

        UserDefaults.standard.set("standard", forKey: key.name)
        postDidChange(for: UserDefaults.standard)

        let vm = ObservableVM(key)
        #expect(vm.value == nil)
    }

    @Test("Local same-value write does not publish")
    @MainActor
    func localSameValueDoesNotPublish() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("no.dup.local", default: 0, container: defaults)
        let vm = ObservableVM(key)

        // First write should publish.
        let first = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        vm.value = 7
        #expect(await first.value, "Expected publication on initial local write")

        // Writing the same value should not publish.
        let second = startWillChangeWaiter(vm, timeoutNanoseconds: 200_000_000)
        await yieldForSubscriptionInstall()
        vm.value = 7
        #expect(!(await second.value), "Should not publish when setting the same value again")
        #expect(defaults.integer(forKey: key.name) == 7)
    }

    @Test("External removal publishes and resets to default - Optional")
    @MainActor
    func externalRemovalOptionalPublishes() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("opt.external.remove", default: nil, container: defaults)
        let vm = ObservableVM(key)

        vm.value = "X"
        #expect(defaults.string(forKey: key.name) == "X")

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.removeObject(forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timeout waiting for removal publication")
        #expect(vm.value == nil)
    }

    @Test("Raw type mismatch falls back to default and publishes")
    @MainActor
    func rawTypeMismatchFallsBackAndPublishes() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("raw.mismatch", default: 123, container: defaults)
        let vm = ObservableVM(key)
        vm.value = 7

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        // Store a String under an Int key
        defaults.set("not an int", forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timeout waiting for mismatch fallback")
        #expect(vm.value == 123)
    }

    @Test("Cross-instance external writes are ignored (documented limitation)")
    @MainActor
    func crossInstanceExternalWritesObservableIgnored() async {
        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)! // different instance, same suite

        let key = DefaultsKey<String?>("cross.instance.observable", default: nil, container: defaultsA)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm, timeoutNanoseconds: 200_000_000)
        await yieldForSubscriptionInstall()

        defaultsB.set("X", forKey: key.name)
        postDidChange(for: defaultsB)

        #expect(!(await waiter.value), "No publication expected from cross-instance write")
        #expect(vm.value == nil)
    }

    @Test("PropertyList extras round-trip: Data and Date")
    @MainActor
    func propertyListExtrasRoundTrip() async {
        let defaults = makeIsolatedDefaults()
        let dataKey = DefaultsKey<Data>("extra.data", default: Data(), container: defaults)
        let dateKey = DefaultsKey<Date>("extra.date", default: Date(timeIntervalSince1970: 0), container: defaults)

        let dataVM = ObservableVM(dataKey)
        let dateVM = ObservableVM(dateKey)

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let when = Date(timeIntervalSince1970: 123_456)

        dataVM.value = payload
        dateVM.value = when

        #expect(defaults.data(forKey: dataKey.name) == payload)
        #expect(defaults.object(forKey: dateKey.name) as? Date == when)

        // External writes should propagate.
        defaults.set(Data([0x01, 0x02]), forKey: dataKey.name)
        defaults.set(Date(timeIntervalSince1970: 654_321), forKey: dateKey.name)
        postDidChange(for: defaults)

        // Allow coalesced refresh to run.
        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(dataVM.value == Data([0x01, 0x02]))
        #expect(dateVM.value == Date(timeIntervalSince1970: 654_321))
    }
}
// MARK: - CodableUserDefault tests

@Suite("VMDefaults - ObservableUserDefault (Codable)")
struct CodableUserDefaultTests {

    /// Sample Codable payload used across tests.
    struct Settings: Codable, Equatable, Sendable {
        var count: Int
        var name: String
    }

    @Test("Default value when missing")
    @MainActor
    func defaultValueWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)

        // With no stored data, wrapper should surface the default and not write anything yet.
        #expect(vm.value == .init(count: 0, name: "zero"))
        #expect(defaults.object(forKey: key.name) == nil)
    }

    @Test("Round-trip local write and read")
    @MainActor
    func roundTripLocalWriteAndRead() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)
        vm.value = .init(count: 3, name: "three")

        // Stored representation is JSON-encoded Data.
        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(Settings.self, from: raw)
        #expect(decoded == .init(count: 3, name: "three"))
    }

    @Test("External write updates and publishes")
    @MainActor
    func externalWriteUpdatesAndPublishes() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        let ext = Settings(count: 9, name: "nine")
        let data = try JSONEncoder().encode(ext)

        defaults.set(data, forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timed out waiting for objectWillChange after external codable write")
        #expect(vm.value == ext)
    }

    @Test("Invalid stored data falls back to default")
    @MainActor
    func invalidStoredDataFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        // Store invalid data for the key; wrapper should fail decode and return the default.
        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        postDidChange(for: defaults)

        let vm = CodableVM(key)
        #expect(vm.value == .init(count: 0, name: "zero"))
    }

    @Test("External removal publishes and resets to default - Codable")
    @MainActor
    func externalRemovalCodablePublishes() async throws {
        struct D: Codable, Equatable, Sendable { var v: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<D>("codable.external.remove", default: .init(v: 0), container: defaults)
        let vm = CodableVM(key)

        vm.value = .init(v: 42)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.removeObject(forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timeout waiting for removal publication")
        #expect(vm.value == .init(v: 0))
    }

    @Test("Invalid external data after init falls back to default and publishes")
    @MainActor
    func invalidExternalDataAfterInitPublishesDefault() async {
        struct S: Codable, Equatable, Sendable { var n: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("codable.invalid.after", default: .init(n: 0), container: defaults)
        let vm = CodableVM(key)
        vm.value = .init(n: 1)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        postDidChange(for: defaults)

        #expect(await waiter.value, "Timeout waiting for invalid data fallback")
        #expect(vm.value == .init(n: 0))
    }

    @Test("Multiple VMs stay in sync - Codable")
    @MainActor
    func multipleCodableVMsStayInSync() async {
        struct C: Codable, Equatable, Sendable { var x: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<C>("codable.sync", default: .init(x: 0), container: defaults)

        let a = CodableVM(key)
        let b = CodableVM(key)

        let waiter = startWillChangeWaiter(b)
        await yieldForSubscriptionInstall()

        a.value = .init(x: 10)

        #expect(await waiter.value, "Timeout waiting for objectWillChange in peer VM")
        #expect(b.value == .init(x: 10))
    }
}
// MARK: - Non-observable accessors

@Suite("VMDefaults - Non-observable accessors")
struct DefaultsAccessorsTests {

    @Test("get() returns default when missing")
    @MainActor
    func getReturnsDefaultWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("plain.missing", default: 42, container: defaults)

        #expect(key.get() == 42)
    }

    @Test("get() returns stored raw value")
    @MainActor
    func getReturnsStoredRawValue() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("plain.raw", default: nil, container: defaults)

        defaults.set("hello", forKey: key.name)
        #expect(key.get() == "hello")
    }

    struct ASettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("get() returns default when missing or invalid")
    @MainActor
    func getCodableReturnsDefaultWhenMissingOrInvalid() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<ASettings>("plain.codable.invalid", default: .init(count: 0, name: "zero"), container: defaults)

        // Missing -> default
        #expect(key.get() == .init(count: 0, name: "zero"))

        // Invalid -> default
        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        #expect(key.get() == .init(count: 0, name: "zero"))
    }

    @Test("get() returns decoded value")
    @MainActor
    func getCodableReturnsDecodedValue() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<ASettings>("plain.codable.valid", default: .init(count: 0, name: "zero"), container: defaults)

        let payload = ASettings(count: 7, name: "seven")
        let data = try JSONEncoder().encode(payload)
        defaults.set(data, forKey: key.name)

        #expect(key.get() == payload)
    }
}
// MARK: - Performance tests (sanity checks, not benchmarks)

@Suite("VMDefaults - Performance")
struct VMDefaultsPerformanceTests {

    /// These are not intended to be "microbenchmarks" (CI machines vary).
    /// They’re quick sanity checks that bulk operations remain reasonable and do not regress badly.

    @Test("Bulk sequential local writes and reads - Observable")
    @MainActor
    func bulkSequentialLocalWritesReadsObservable() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("perf.int.local", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 2_000
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations { vm.value = i }

        let writeDuration = start.duration(to: clock.now)

        #expect(vm.value == iterations)
        #expect(defaults.integer(forKey: key.name) == iterations)

        var sum = 0
        for _ in 0..<iterations { sum += vm.value }
        #expect(sum >= iterations)

        print("[Perf][Observable] local writes: \(writeDuration)")
    }

    @Test("Bulk sequential external writes - Observable")
    @MainActor
    func bulkSequentialExternalWritesObservable() async throws {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("perf.int.external", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 1_000
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations {
            defaults.set(i, forKey: key.name)
            postDidChange(for: defaults)
        }

        let duration = start.duration(to: clock.now)

        // Allow the final coalesced refresh task to run.
        try await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(vm.value == iterations)

        print("[Perf][Observable] external writes: \(duration)")
    }

    struct PSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("Bulk sequential local writes and reads - Codable")
    @MainActor
    func bulkSequentialLocalWritesReadsCodable() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<PSettings>("perf.codable.local", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let iterations = 500
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations { vm.value = .init(count: i, name: "n\(i)") }

        let writeDuration = start.duration(to: clock.now)

        #expect(vm.value == .init(count: iterations, name: "n\(iterations)"))

        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(PSettings.self, from: raw)
        #expect(decoded == .init(count: iterations, name: "n\(iterations)"))

        print("[Perf][Codable] local writes: \(writeDuration)")
    }

    @Test("Bulk sequential external writes - Codable")
    @MainActor
    func bulkSequentialExternalWritesCodable() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<PSettings>("perf.codable.external", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let iterations = 300
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations {
            let payload = PSettings(count: i, name: "n\(i)")
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: key.name)
            postDidChange(for: defaults)
        }

        let duration = start.duration(to: clock.now)

        try await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(vm.value == .init(count: iterations, name: "n\(iterations)"))

        print("[Perf][Codable] external writes: \(duration)")
    }
}
// MARK: - Concurrency / stress tests (best-effort)

@Suite("VMDefaults - Concurrency")
struct VMDefaultsConcurrencyTests {

    /// These tests intentionally create “messy” write patterns.
    /// We don’t assert a specific final value (because last-writer-wins is timing-dependent),
    /// but we *do* assert internal consistency:
    /// - VM value equals what’s stored in defaults
    /// - Final value is one of the values we wrote

    @Test("Concurrent external writes - Observable")
    @MainActor
    func concurrentExternalWritesObservable() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("conc.observable", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let values = (0..<50).map { "V\($0)" }

        // Write from background tasks to simulate “external” writers.
        let tasks = values.map { v in
            Task { @Sendable in
                defaults.set(v, forKey: key.name)
                postDidChange(for: defaults)
            }
        }
        for t in tasks { _ = await t.value }

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let final = vm.value
        #expect(final == nil || values.contains(final!))
        #expect(defaults.string(forKey: key.name) == final)
    }

    @Test("Concurrent external writes - Codable")
    @MainActor
    func concurrentExternalWritesCodable() async throws {
        struct CSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<CSettings>("conc.codable", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let pairs = (0..<40).map { (i: $0, s: "n\($0)") }

        let tasks = pairs.map { pair in
            Task { @Sendable in
                let payload = CSettings(count: pair.i, name: pair.s)
                let data = try JSONEncoder().encode(payload)
                defaults.set(data, forKey: key.name)
                postDidChange(for: defaults)
            }
        }
        for t in tasks { _ = try await t.value }

        try await Task.sleep(nanoseconds: propagationDelayNanos)

        let final = vm.value
        #expect(pairs.contains(where: { $0.i == final.count && $0.s == final.name }))
    }

    @Test("Concurrent main-actor local writes - Observable")
    @MainActor
    func concurrentMainActorLocalWritesObservable() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("conc.local.observable", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 500

        // Many tasks hopping to MainActor; they serialize, so last write should win deterministically.
        let tasks = (1...iterations).map { i in
            Task { @MainActor in vm.value = i }
        }
        for t in tasks { _ = await t.value }

        #expect(vm.value == iterations)
        #expect(defaults.integer(forKey: key.name) == iterations)
    }

    @Test("Mixed local and external writes - Observable")
    @MainActor
    func mixedLocalAndExternalWritesObservable() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("conc.mixed.observable", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 200
        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(iterations * 2)

        for i in 1...iterations {
            tasks.append(Task { @MainActor in vm.value = "L\(i)" })
            tasks.append(Task { @Sendable in
                defaults.set("E\(i)", forKey: key.name)
                postDidChange(for: defaults)
            })
        }

        for t in tasks { _ = await t.value }

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let final = vm.value
        #expect(final != nil)

        let acceptable = Set((1...iterations).map { "L\($0)" } + (1...iterations).map { "E\($0)" })
        #expect(final.map { acceptable.contains($0) } ?? false)
        #expect(defaults.string(forKey: key.name) == final)
    }

    @Test("Mixed local and external writes - Codable")
    @MainActor
    func mixedLocalAndExternalWritesCodable() async throws {
        struct MSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<MSettings>("conc.mixed.codable", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let iterations = 150
        var localTasks: [Task<Void, Never>] = []
        var externalTasks: [Task<Void, Error>] = []
        localTasks.reserveCapacity(iterations)
        externalTasks.reserveCapacity(iterations)

        for i in 1...iterations {
            localTasks.append(Task { @MainActor in vm.value = .init(count: i, name: "L\(i)") })
            externalTasks.append(Task { @Sendable in
                let payload = MSettings(count: i, name: "E\(i)")
                let data = try JSONEncoder().encode(payload)
                defaults.set(data, forKey: key.name)
                postDidChange(for: defaults)
            })
        }

        for t in localTasks { _ = await t.value }
        for t in externalTasks { _ = try await t.value }

        try await Task.sleep(nanoseconds: propagationDelayNanos)

        let final = vm.value
        let isLocal = final.name.hasPrefix("L") && (1...iterations).contains(final.count)
        let isExternal = final.name.hasPrefix("E") && (1...iterations).contains(final.count)
        #expect(isLocal || isExternal)
    }
}
// MARK: - Non-observable reactive APIs
@Suite("VMDefaults - Non-observable reactive APIs")
struct DefaultsReactiveTests {

    @Test("Raw publisher emits initial and updates, with removeDuplicates")
    @MainActor
    func rawPublisherEmits() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("react.raw", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = key.distinctPublisher().sink { received.append($0) }

        // Initial value
        #expect(received == [0])

        // External writes
        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        defaults.set(1, forKey: key.name) // duplicate should be removed
        postDidChange(for: defaults)
        defaults.set(2, forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: 30_000_000)

        // Depending on coalescing, the duplicate 1 and timing may skip the first 1 emission.
        let okSequences: [[Int]] = [[0, 1, 2], [0, 2]]
        #expect(okSequences.contains(where: { $0 == received }))

        _ = cancellable // keep alive
    }

    @Test("Raw async updates emit initial and coalesced changes")
    @MainActor
    func rawAsyncUpdatesEmit() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("react.async.raw", default: nil, container: defaults)

        var values: [String?] = []
        // Collect updates on a separate task; we'll cancel it at the end to avoid indefinite waits.
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        // Give the iterator a moment to yield the initial value before we start writing.
        try? await Task.sleep(nanoseconds: 10_000_000)

        defaults.set("A", forKey: key.name)
        postDidChange(for: defaults)

        // Space writes to reduce coalescing; keep tests fast but reliable.
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set("B", forKey: key.name)
        postDidChange(for: defaults)

        // Allow time for B to propagate, then cancel the collector to avoid hanging.
        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        collector.cancel()

        // Assert semantic properties instead of exact sequences:
        #expect(!values.isEmpty, "Should receive at least the initial emission")
        #expect(values[0] == nil, "Initial emission should be nil")
        #expect(values.last == "B", "Final emission should be the last value we wrote")
        #expect(values.count >= 2 && values.count <= 3, "Expect 2 or 3 emissions depending on coalescing")
        if values.count == 3 { #expect(values[1] == "A", "If three emissions occur, the middle one should be A") }
    }

    struct RSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("Codable publisher emits initial and updates")
    @MainActor
    func codablePublisherEmits() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<RSettings>("react.codable.pub", default: .init(count: 0, name: "zero"), container: defaults)

        var received: [RSettings] = []
        let cancellable = key.distinctPublisher().sink { received.append($0) }

        // Initial default
        #expect(received == [.init(count: 0, name: "zero")])

        let a = RSettings(count: 1, name: "one")
        let b = RSettings(count: 2, name: "two")
        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        defaults.set(try JSONEncoder().encode(a), forKey: key.name) // duplicate
        postDidChange(for: defaults)
        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: 30_000_000)
        let okCodablePub: [[RSettings]] = [[.init(count: 0, name: "zero"), a, b], [.init(count: 0, name: "zero"), b]]
        #expect(okCodablePub.contains(where: { $0 == received }))

        _ = cancellable
    }

    @Test("Codable async updates emit initial and updates")
    @MainActor
    func codableAsyncUpdatesEmit() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<RSettings>("react.codable.async", default: .init(count: 0, name: "zero"), container: defaults)

        var values: [RSettings] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        // Give the iterator a moment to yield the initial default before writes.
        try? await Task.sleep(nanoseconds: 10_000_000)

        let a = RSettings(count: 3, name: "three")
        let b = RSettings(count: 4, name: "four")

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        collector.cancel()

        #expect(values.first == .init(count: 0, name: "zero"), "Initial emission should be the default value")
        #expect(values.last == b, "Final emission should be the last value we wrote")
        #expect(values.count >= 2 && values.count <= 3, "Expect 2 or 3 emissions depending on coalescing")
        if values.count == 3 { #expect(values[1] == a, "If three emissions occur, the middle one should be 'a'") }
    }

    @Test("Reactive publisher uses provided container, not standard")
    @MainActor
    func reactivePublisherUsesProvidedContainerNotStandard() async {
        let isolated = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("react.container.isolation", default: 1, container: isolated)

        var values: [Int] = []
        let cancellable = key.distinctPublisher().sink { values.append($0) }
        #expect(values == [1])
        UserDefaults.standard.set(99, forKey: key.name)
        postDidChange(for: UserDefaults.standard)
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Should not observe standard container changes
        #expect(!values.contains(99))
        _ = cancellable
    }

    @Test("Reactive publisher does not emit for cross-instance writes (same suite)")
    @MainActor
    func reactivePublisherCrossInstanceIgnored() async {
        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)!

        let key = DefaultsKey<Int>("react.cross.instance", default: 0, container: defaultsA)

        var received: [Int] = []
        let cancellable = key.distinctPublisher().sink { received.append($0) }
        #expect(received == [0])

        defaultsB.set(5, forKey: key.name)
        postDidChange(for: defaultsB)
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(!received.contains(5))
        _ = cancellable
    }
}

