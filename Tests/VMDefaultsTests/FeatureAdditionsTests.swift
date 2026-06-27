//
//  FeatureAdditionsTests.swift
//  VMDefaults
//
//  Coverage for the additive features: TransformedDefaultsKey (RawRepresentable / URL / UUID raw
//  storage), reset()/isStored, the app-group helper, and debouncedUpdates.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

private enum Theme: String, CaseIterable, Sendable, Equatable {
    case light, dark, system
}

@MainActor
private final class ThemeVM: ObservableObject {
    @ObservableUserDefault var theme: Theme
    init(_ container: UserDefaults) {
        _theme = ObservableUserDefault(TransformedDefaultsKey(rawRepresentable: "theme-vm", default: .system, container: container))
        activateDefaultsBindings()
    }
}

// MARK: - RawRepresentable storage

@Suite("VMDefaults - RawRepresentable storage")
struct RawRepresentableTests {

    @MainActor
    @Test("Enum round-trips through its raw value")
    func enumRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let key = TransformedDefaultsKey(rawRepresentable: "theme", default: Theme.system, container: defaults)

        #expect(key.get() == .system)        // default (key missing)
        key.set(.dark)
        #expect(key.get() == .dark)
        #expect(defaults.string(forKey: "theme") == "dark") // stored as native String, not JSON
        key.reset()
        #expect(key.get() == .system)
    }

    @MainActor
    @Test("Unknown stored raw value falls back to the default")
    func unknownRawFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        let key = TransformedDefaultsKey(rawRepresentable: "theme-bad", default: Theme.light, container: defaults)

        defaults.set("chartreuse", forKey: "theme-bad") // not a Theme case
        #expect(key.get() == .light)
    }

    @MainActor
    @Test("@ObservableUserDefault drives an enum and forwards external writes")
    func observableEnumForwards() async {
        let defaults = makeIsolatedDefaults()
        let vm = ThemeVM(defaults)
        #expect(vm.theme == .system)

        vm.theme = .dark
        #expect(vm.theme == .dark)
        #expect(defaults.string(forKey: "theme-vm") == "dark")

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()
        defaults.set("light", forKey: "theme-vm")
        #expect(await waiter.value)
        #expect(vm.theme == .light)
    }
}

// MARK: - URL / UUID storage

@Suite("VMDefaults - URL & UUID storage")
struct URLUUIDTests {

    @MainActor
    @Test("URL round-trips as absoluteString")
    func urlRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let home = URL(string: "https://example.com")!
        let key = TransformedDefaultsKey(url: "homepage", default: home, container: defaults)

        #expect(key.get() == home)
        let apple = URL(string: "https://apple.com/path?q=1")!
        key.set(apple)
        #expect(key.get() == apple)
        #expect(defaults.string(forKey: "homepage") == apple.absoluteString)
    }

    @MainActor
    @Test("UUID round-trips as uuidString")
    func uuidRoundTrips() {
        let defaults = makeIsolatedDefaults()
        let fallback = UUID()
        let key = TransformedDefaultsKey(uuid: "device-id", default: fallback, container: defaults)

        #expect(key.get() == fallback)
        let id = UUID()
        key.set(id)
        #expect(key.get() == id)
        #expect(defaults.string(forKey: "device-id") == id.uuidString)
    }
}

// MARK: - reset() / isStored

@Suite("VMDefaults - reset() and isStored")
struct ResetAndExistenceTests {

    @MainActor
    @Test("Raw key reset() restores default and isStored tracks presence")
    func rawResetAndIsStored() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("reset-raw", default: 0, container: defaults)

        #expect(key.isStored == false)
        key.set(5)
        #expect(key.isStored == true)
        #expect(key.get() == 5)
        key.reset()
        #expect(key.isStored == false)
        #expect(key.get() == 0)
    }

    @MainActor
    @Test("Codable key reset() restores default and isStored tracks presence")
    func codableResetAndIsStored() {
        struct S: Codable, Equatable, Sendable { var n: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("reset-codable", default: .init(n: 0), container: defaults)

        #expect(key.isStored == false)
        key.set(.init(n: 9))
        #expect(key.isStored == true)
        #expect(key.get() == .init(n: 9))
        key.reset()
        #expect(key.isStored == false)
        #expect(key.get() == .init(n: 0))
    }
}

// MARK: - App-group helper

@Suite("VMDefaults - App-group helper")
struct AppGroupHelperTests {

    @MainActor
    @Test("appGroup(_:) returns a usable suite")
    func appGroupReturnsUsableSuite() {
        let suite = "VMDefaultsTests.appgroup.\(UUID().uuidString)"
        let defaults = UserDefaults.appGroup(suite)
        #expect(defaults != nil)
        defaults?.set(7, forKey: "ag-x")
        #expect(defaults?.integer(forKey: "ag-x") == 7)
        defaults?.removePersistentDomain(forName: suite)
    }
}

// MARK: - Debounce

@Suite("VMDefaults - Debounced updates")
struct DebounceTests {

    @MainActor
    @Test("debouncedUpdates collapses a rapid burst to the final value")
    func debounceCollapsesRapidBurst() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("debounce", default: 0, container: defaults)

        var values: [Int] = []
        let collector = Task { @MainActor in
            for await v in key.debouncedUpdates(for: .milliseconds(40)) {
                values.append(v)
                if v == 5 { break }
            }
        }

        await yieldForSubscriptionInstall()

        // Rapid synchronous burst — all land well within one 40ms debounce window.
        for i in 1...5 { defaults.set(i, forKey: key.name) }

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values.last == 5)
        #expect(values.count < 5) // debounced: intermediate values were dropped
    }
}
