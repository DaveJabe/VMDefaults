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
private final class ObservableVM<Value: Equatable & Sendable>: ObservableObject {
    @ObservableUserDefault var value: Value

    init(_ key: DefaultsKey<Value>) {
        _value = ObservableUserDefault(key)
        _ = value // installs the wrapper's forwarding subscription eagerly
    }
}

/// Minimal `ObservableObject` used to test `@CodableUserDefault`.
@MainActor
private final class CodableVM<Value: Codable & Equatable & Sendable>: ObservableObject {
    @CodableUserDefault var value: Value

    init(_ key: DefaultsKey<Value>) {
        _value = CodableUserDefault(key)
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
}

// MARK: - CodableUserDefault tests

@Suite("VMDefaults - CodableUserDefault")
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
        let key = DefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)

        // With no stored data, wrapper should surface the default and not write anything yet.
        #expect(vm.value == .init(count: 0, name: "zero"))
        #expect(defaults.object(forKey: key.name) == nil)
    }

    @Test("Round-trip local write and read")
    @MainActor
    func roundTripLocalWriteAndRead() throws {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

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
        let key = DefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

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
        let key = DefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        // Store invalid data for the key; wrapper should fail decode and return the default.
        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        postDidChange(for: defaults)

        let vm = CodableVM(key)
        #expect(vm.value == .init(count: 0, name: "zero"))
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
        let key = DefaultsKey<PSettings>("perf.codable.local", default: .init(count: 0, name: "zero"), container: defaults)
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
        let key = DefaultsKey<PSettings>("perf.codable.external", default: .init(count: 0, name: "zero"), container: defaults)
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
        let key = DefaultsKey<CSettings>("conc.codable", default: .init(count: 0, name: "zero"), container: defaults)
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
        let key = DefaultsKey<MSettings>("conc.mixed.codable", default: .init(count: 0, name: "zero"), container: defaults)
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
