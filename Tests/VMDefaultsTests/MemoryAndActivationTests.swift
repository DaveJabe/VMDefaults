//
//  MemoryAndActivationTests.swift
//  VMDefaults
//
//  Coverage for object-graph teardown (retain-cycle regression guard), the lazy-binding
//  activation trap and its `activateDefaultsBindings()` fix, multi-property view models, and the
//  string-based initializers — the areas the audit flagged as structurally untested.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

// MARK: - Test view models (file scope to satisfy @ObservableUserDefault's class requirement)

/// A VM that never reads its property and never activates bindings — exercises the lazy trap.
@MainActor
private final class NeverAccessedVM: ObservableObject {
    @ObservableUserDefault var value: Int
    init(_ key: DefaultsKey<Int>) {
        _value = ObservableUserDefault(key)
        // Intentionally NO `_ = value` and NO activateDefaultsBindings().
    }
}

/// A VM that activates bindings without ever reading the property.
@MainActor
private final class ActivatedVM: ObservableObject {
    @ObservableUserDefault var value: Int
    init(_ key: DefaultsKey<Int>) {
        _value = ObservableUserDefault(key)
        activateDefaultsBindings()
    }
}

/// A VM with several wrapped properties of different types, activated together.
@MainActor
private final class MultiVM: ObservableObject {
    @ObservableUserDefault var count: Int
    @ObservableUserDefault var name: String
    @ObservableUserDefault var enabled: Bool
    init(_ container: UserDefaults) {
        _count = ObservableUserDefault(DefaultsKey("multi-count", default: 0, container: container))
        _name = ObservableUserDefault(DefaultsKey("multi-name", default: "", container: container))
        _enabled = ObservableUserDefault(DefaultsKey("multi-enabled", default: false, container: container))
        activateDefaultsBindings()
    }
}

/// VMs built through the string-based initializers (otherwise unexercised).
@MainActor
private final class StringRawVM: ObservableObject {
    @ObservableUserDefault var value: Int
    init(_ container: UserDefaults) {
        _value = ObservableUserDefault(key: "str-raw", defaultValue: 7, container: container)
        activateDefaultsBindings()
    }
}

private struct StringCodablePayload: Codable, Equatable, Sendable { var n: Int }

@MainActor
private final class StringCodableVM: ObservableObject {
    @ObservableUserDefault var value: StringCodablePayload
    init(_ container: UserDefaults) {
        _value = ObservableUserDefault(codableKey: "str-codable", defaultValue: .init(n: 3), container: container)
        activateDefaultsBindings()
    }
}

// MARK: - Retain-cycle / deallocation

@Suite("VMDefaults - Memory & deallocation")
struct MemoryTests {

    /// The headline regression guard: a bound `@ObservableUserDefault` must not leak its
    /// token + cancellable + Combine sink when the enclosing view model deallocates. We weak-
    /// reference the actual binding token; with the retain cycle present it survives the VM,
    /// with the fix it deallocates. (A `weak var vm` would NOT catch this — the leaked token
    /// captured `instance` weakly, so the VM itself still died. This is also parallelism-safe:
    /// it tracks one specific object, not shared global state.)
    @MainActor
    @Test("Bound view models release their binding token graph on deallocation")
    func boundViewModelsReleaseTokens() async {
        let defaults = makeIsolatedDefaults()
        weak var weakToken: _DefaultsBindingToken?

        do {
            let key = DefaultsKey<Int>("leak-vm", default: 0, container: defaults)
            let vm = ObservableVM(key) // eager-binds in init
            vm.value = 1               // exercise the internal-write path (re-fires KVO)
            #expect(vm.value == 1)

            let tokens = _bindingTokens(of: vm)
            #expect(tokens.count == 1)
            weakToken = tokens.first
            #expect(weakToken != nil)
        }

        // ARC frees synchronously, but allow any pending main-actor refresh tasks to drain.
        await drainMainActor()
        #expect(weakToken == nil)
    }

    @MainActor
    @Test("A deallocated view model's key write does not crash and forwards to nothing")
    func deallocatedViewModelDoesNotCrashOnLaterWrite() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("leak-after-write", default: 0, container: defaults)
        weak var weakToken: _DefaultsBindingToken?

        do {
            let vm = ObservableVM(key)
            _ = vm.value
            weakToken = _bindingTokens(of: vm).first
        }
        await drainMainActor()
        #expect(weakToken == nil)

        // Writing the key after the observer is gone must be a harmless no-op (observer removed).
        defaults.set(123, forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(defaults.integer(forKey: key.name) == 123)
    }

    @MainActor
    @Test("Repeated create/destroy cycles leave no surviving tokens")
    func repeatedCreateDestroyDoesNotAccumulate() async {
        let defaults = makeIsolatedDefaults()
        var weakTokens: [() -> Bool] = [] // each closure reports whether its token is still alive

        for i in 0..<20 {
            do {
                let key = DefaultsKey<Int>("churn-\(i)", default: 0, container: defaults)
                let vm = ObservableVM(key)
                vm.value = i
                weak let t = _bindingTokens(of: vm).first
                weakTokens.append { t != nil }
            }
        }
        await drainMainActor()
        #expect(weakTokens.allSatisfy { $0() == false })
    }
}

// MARK: - Lazy binding trap & activateDefaultsBindings()

@Suite("VMDefaults - Lazy binding & activation")
struct ActivationTests {

    @MainActor
    @Test("A never-accessed, never-activated property does NOT forward external writes")
    func lazyUnboundPropertyDoesNotForward() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("lazy-unbound", default: 0, container: defaults)
        let vm = NeverAccessedVM(key)

        // No access has installed the binding yet → external write must not fire objectWillChange.
        let waiter = startWillChangeWaiter(vm, timeoutNanoseconds: 300_000_000)
        await yieldForSubscriptionInstall()
        defaults.set(5, forKey: key.name)
        let firedBeforeAccess = await waiter.value
        #expect(firedBeforeAccess == false)

        // First read installs the binding and reflects the externally-written value...
        #expect(vm.value == 5)

        // ...and subsequent external writes now DO forward.
        let waiter2 = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set(7, forKey: key.name)
        #expect(await waiter2.value)
        #expect(vm.value == 7)
    }

    @MainActor
    @Test("activateDefaultsBindings() forwards external writes without ever reading the property")
    func activatedPropertyForwardsWithoutAccess() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("activated", default: 0, container: defaults)
        let vm = ActivatedVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set(42, forKey: key.name)
        #expect(await waiter.value)
        #expect(vm.value == 42)
    }
}

// MARK: - Multi-property view models

@Suite("VMDefaults - Multi-property view models")
struct MultiPropertyTests {

    @MainActor
    @Test("Properties are independent and a local write fires objectWillChange exactly once")
    func independentPropertiesSingleWillChange() async {
        let defaults = makeIsolatedDefaults()
        let vm = MultiVM(defaults)

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        vm.count = 1
        await drainMainActor()

        #expect(vm.count == 1)
        #expect(vm.name == "")          // untouched
        #expect(vm.enabled == false)    // untouched
        #expect(willChanges == 1)       // exactly one send for the single local write
        _ = cancellable
    }

    @MainActor
    @Test("An external write to one key forwards only through its own property")
    func externalWriteForwardsPerProperty() async {
        let defaults = makeIsolatedDefaults()
        let vm = MultiVM(defaults)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set("hello", forKey: "multi-name")
        #expect(await waiter.value)

        #expect(vm.name == "hello")
        #expect(vm.count == 0)          // sibling unaffected
        #expect(vm.enabled == false)    // sibling unaffected
    }
}

// MARK: - String-based initializers

@Suite("VMDefaults - String-based initializers")
struct StringInitializerTests {

    @MainActor
    @Test("init(key:defaultValue:container:) round-trips and forwards")
    func stringRawInitRoundTrips() async {
        let defaults = makeIsolatedDefaults()
        let vm = StringRawVM(defaults)
        #expect(vm.value == 7) // default

        vm.value = 99
        #expect(vm.value == 99)
        #expect(defaults.integer(forKey: "str-raw") == 99)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set(123, forKey: "str-raw")
        #expect(await waiter.value)
        #expect(vm.value == 123)
    }

    @MainActor
    @Test("init(codableKey:defaultValue:container:) round-trips and forwards")
    func stringCodableInitRoundTrips() async throws {
        let defaults = makeIsolatedDefaults()
        let vm = StringCodableVM(defaults)
        #expect(vm.value == .init(n: 3)) // default

        vm.value = .init(n: 5)
        #expect(vm.value == .init(n: 5))

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set(try JSONEncoder().encode(StringCodablePayload(n: 8)), forKey: "str-codable")
        #expect(await waiter.value)
        #expect(vm.value == .init(n: 8))
    }
}
