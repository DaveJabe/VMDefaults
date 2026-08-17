//
//  InitAndTeardownRaceTests.swift
//  VMDefaults
//
//  Coverage for the two lifecycle races the audit flagged as untested:
//    1. An external write landing *during* observation installation (after the initial snapshot
//       is read, before the KVO observer is registered) must not be lost — the package's core
//       cross-process sync promise. Exercised deterministically via the DEBUG-only
//       `UserDefaultsKeyObservation._setBeforeInstallHook` seam rather than a timing stress.
//    2. Tearing a view model down while background threads hammer its key (KVO observer removal
//       under fire) must neither crash nor corrupt state — the README explicitly blesses
//       background-thread external writes.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Init-window race (hook-based, deterministic)

// Serialized: the before-install hook is process-global state; parallel tests in this suite
// would overwrite each other's hook. (Each hook still filters on its own unique key name, so
// observations created concurrently by *other* suites are unaffected no-ops.)
@Suite("VMDefaults - Init observation window", .serialized)
struct InitObservationWindowTests {

    @MainActor
    @Test("A write landing between the wrapper's snapshot and observer installation is not lost")
    func wrapperInitWindowWriteConverges() async {
        let defaults = makeIsolatedDefaults()
        let keyName = "init-window-vm-\(UUID().uuidString)"
        let key = DefaultsKey<Int>(keyName, default: 0, container: defaults)

        // From inside the installation window: the wrapper has already read its initial snapshot
        // (0, key missing), but the KVO observer is not yet registered — so this write fires no
        // observation. Without a post-install re-read the box would stay stale indefinitely
        // (e.g. a widget writing while the app launches).
        UserDefaultsKeyObservation._setBeforeInstallHook { hookDefaults, hookKey in
            guard hookKey == keyName else { return }
            hookDefaults.set(42, forKey: hookKey)
        }
        defer { UserDefaultsKeyObservation._setBeforeInstallHook(nil) }

        let vm = ObservableVM(key)

        // No further writes: the value must converge from init alone.
        await drainMainActor()
        #expect(vm.value == 42)
    }

    @MainActor
    @Test("updates() reflects a write landing during observation installation in its initial value")
    func updatesInitWindowWriteIsReflected() async {
        let defaults = makeIsolatedDefaults()
        let keyName = "init-window-stream-\(UUID().uuidString)"
        let key = DefaultsKey<Int>(keyName, default: 0, container: defaults)

        UserDefaultsKeyObservation._setBeforeInstallHook { hookDefaults, hookKey in
            guard hookKey == keyName else { return }
            hookDefaults.set(7, forKey: hookKey)
        }
        defer { UserDefaultsKeyObservation._setBeforeInstallHook(nil) }

        // _coalescedStream installs the observer (via _keyChanges) BEFORE taking its initial
        // read, so the hook's write must already be visible in the first yielded value.
        var first: Int?
        for await value in key.updates() {
            first = value
            break
        }
        #expect(first == 7)
    }
}

// MARK: - Teardown under background write fire

@Suite("VMDefaults - Teardown under write fire")
struct TeardownUnderFireTests {

    /// Repeatedly drops a bound view model while detached tasks hammer its key from background
    /// threads. KVO observer removal racing synchronous delivery on the writers' threads is the
    /// classic teardown hazard; this pins that the whole path (box deinit → observation
    /// invalidate → removeObserver) is safe under fire. Run with `--sanitize=thread` in CI for
    /// full effect; even unsanitized, a regression here crashes the test process.
    @MainActor
    @Test("Dropping a bound VM while background threads write its key does not crash")
    func teardownWhileBackgroundThreadsWrite() async {
        let defaults = makeIsolatedDefaults()

        for cycle in 0..<15 {
            let key = DefaultsKey<Int>("teardown-fire-\(cycle)", default: 0, container: defaults)
            var writers: [Task<Void, Never>] = []

            do {
                let vm = ObservableVM(key) // eager-binds in init
                #expect(vm.value == 0)

                // @Sendable (non-isolated) closures run on the global executor — i.e. off the
                // main actor — matching the package's other concurrency tests.
                writers = (0..<4).map { writer in
                    Task { @Sendable in
                        for i in 0..<25 {
                            defaults.set(writer * 1_000 + i, forKey: key.name)
                        }
                    }
                }

                // Let some writes land (and KVO deliveries start) while the VM is still alive,
                // then drop it mid-fire at scope exit.
                await Task.yield()
            }

            for writer in writers { await writer.value }
            await drainMainActor()

            // The store itself must remain healthy: the last landed write is readable.
            let final = defaults.integer(forKey: key.name)
            #expect((0..<4).contains(final / 1_000) && (0..<25).contains(final % 1_000))
        }
    }
}
