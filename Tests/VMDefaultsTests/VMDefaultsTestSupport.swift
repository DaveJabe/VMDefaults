//
//  VMDefaultsTestSupport.swift
//  VMDefaults
//
//  Shared test utilities and helpers used across multiple test suites.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Shared constants

/// Default timeout used when waiting for `objectWillChange`.
let willChangeTimeoutNanos: UInt64 = 2_000_000_000

/// Small delay used after posting external writes to allow coalesced refresh.
let propagationDelayNanos: UInt64 = 30_000_000 // 30ms

// MARK: - Test helpers (UserDefaults + notifications)

/// Creates an isolated UserDefaults suite for a single test.
func makeIsolatedDefaults() -> UserDefaults {
    let suite = "VMDefaultsTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

// Note: observation in VMDefaults is KVO-based (per-key, suite-scoped). Real writes via
// `UserDefaults.set`/`removeObject` drive updates directly; manually posting
// `UserDefaults.didChangeNotification` has no effect on the package and is not used in tests.

// MARK: - Test helpers (waiting for objectWillChange)

/// File-scope gate to avoid Swift's "nested type in generic function" restriction.
final class _WillChangeGate {
    var didResume = false
    var cancellable: AnyCancellable?
}

/// Waits for the next `objectWillChange` emission or times out.
@MainActor
func waitForObjectWillChange(
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
func startWillChangeWaiter(
    _ object: some ObservableObject,
    timeoutNanoseconds: UInt64 = willChangeTimeoutNanos
) -> Task<Bool, Never> {
    Task { @MainActor in
        await waitForObjectWillChange(object, timeoutNanoseconds: timeoutNanoseconds)
    }
}

/// Cheap “yield” to let the waiter subscription install before we trigger an event.
@MainActor
func yieldForSubscriptionInstall() async {
    await Task.yield()
}

/// Lets any pending main-actor tasks (e.g. KVO-driven `coalescedRefresh` hops) run and gives ARC
/// a moment to settle, without a wall-clock sleep. Used by deallocation tests.
@MainActor
func drainMainActor(turns: Int = 8) async {
    for _ in 0..<turns { await Task.yield() }
}

// MARK: - Generic test view models

/// Minimal `ObservableObject` used to test `@ObservableUserDefault` across many `Value` types.
@MainActor
final class ObservableVM<Value: Equatable & Sendable & PropertyListValue>: ObservableObject {
    @ObservableUserDefault var value: Value

    init(_ key: DefaultsKey<Value>) {
        _value = ObservableUserDefault(key)
        _ = value // installs the wrapper's forwarding subscription eagerly
    }
}

/// Minimal `ObservableObject` used to test `@ObservableUserDefault` with Codable values.
@MainActor
final class CodableVM<Value: Codable & Equatable & Sendable>: ObservableObject {
    @ObservableUserDefault var value: Value

    init(_ key: CodableDefaultsKey<Value>) {
        _value = ObservableUserDefault(key)
        _ = value // installs the wrapper's forwarding subscription eagerly
    }
}
