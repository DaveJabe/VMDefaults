//
//  WrapperPublishingContractTests.swift
//  VMDefaults
//
//  Pins the README "Publishing semantics" contract at the wrapper level — the package's core
//  product surface, previously only covered via streams/get():
//    - setting an equal value sends no objectWillChange
//    - objectWillChange fires BEFORE the property value changes (willSet semantics), for both
//      local and external writes
//    - corrupt external data (invalid Codable bytes, raw type mismatch, undecodable transformed
//      raw value) falls back to the default with exactly one publication, and the wrapper-level
//      onError/encoder/decoder parameters are exercised
//    - a local write whose Codable encode throws: onError fires, the store is untouched, and the
//      in-memory value diverges until the next external change (current, documented-by-test behavior)
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

/// Counts (not just records) error-handler invocations.
private final class ErrorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func record() { lock.lock(); _count += 1; lock.unlock() }
}

/// `CodableVM` variant that exposes the wrapper's `encoder`/`decoder`/`onError` parameters.
@MainActor
private final class OnErrorCodableVM<Value: Codable & Equatable & Sendable>: ObservableObject {
    @ObservableUserDefault var value: Value
    init(
        _ key: CodableDefaultsKey<Value>,
        encoder: JSONEncoder = .init(),
        decoder: JSONDecoder = .init(),
        onError: @escaping @Sendable (Error) -> Void
    ) {
        _value = ObservableUserDefault(key, encoder: encoder, decoder: decoder, onError: onError)
        activateDefaultsBindings()
    }
}

private enum PinTheme: String, Sendable, Equatable {
    case light, dark, system
}

@MainActor
private final class ThemePinVM: ObservableObject {
    @ObservableUserDefault var theme: PinTheme
    init(_ container: UserDefaults) {
        _theme = ObservableUserDefault(TransformedDefaultsKey(rawRepresentable: "theme-pin", default: .system, container: container))
        activateDefaultsBindings()
    }
}

/// Encodes normally unless `explode` is set, in which case `encode(to:)` throws.
private struct FailingEncodable: Codable, Equatable, Sendable {
    var v: Int
    var explode: Bool = false

    enum Boom: Error { case boom }

    init(v: Int, explode: Bool = false) {
        self.v = v
        self.explode = explode
    }

    enum CodingKeys: String, CodingKey { case v }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try container.decode(Int.self, forKey: .v)
        self.explode = false
    }
    func encode(to encoder: Encoder) throws {
        if explode { throw Boom.boom }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
    }
}

// MARK: - Equal-value writes

@Suite("VMDefaults - Equal-value write suppression")
struct EqualValueWriteTests {

    @MainActor
    @Test("Setting the same value again sends no objectWillChange")
    func settingEqualValueSendsNoObjectWillChange() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("equal-set", default: 0, container: defaults)
        let vm = ObservableVM(key)

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        vm.value = 5
        await drainMainActor() // let the local write's KVO echo settle (it must not re-publish)
        #expect(willChanges == 1)

        vm.value = 5 // same value again — README: "objectWillChange is not sent"
        await drainMainActor()
        #expect(willChanges == 1)
        #expect(vm.value == 5)

        // Sanity: the counter is still live — a different value publishes again.
        vm.value = 6
        #expect(willChanges == 2)
        _ = cancellable
    }
}

// MARK: - willSet semantics

@Suite("VMDefaults - objectWillChange ordering (willSet)")
struct WillSetOrderingTests {

    @MainActor
    @Test("objectWillChange fires before the property changes on a local write")
    func localWritePublishesBeforeValueChanges() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("willset-local", default: 0, container: defaults)
        let vm = ObservableVM(key)

        var observedAtWillChange: [Int] = []
        let cancellable = vm.objectWillChange.sink { _ in
            // The send arrives synchronously on the main actor for both local writes (subscript
            // set) and external writes (coalescedRefresh runs on the main actor).
            MainActor.assumeIsolated { observedAtWillChange.append(vm.value) }
        }

        vm.value = 7

        // SwiftUI diffing depends on reading the OLD value during objectWillChange.
        #expect(observedAtWillChange == [0])
        #expect(vm.value == 7)
        _ = cancellable
    }

    @MainActor
    @Test("objectWillChange fires before the property changes on an external write")
    func externalWritePublishesBeforeValueChanges() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("willset-external", default: 0, container: defaults)
        let vm = ObservableVM(key)

        var observedAtWillChange: [Int] = []
        let cancellable = vm.objectWillChange.sink { _ in
            MainActor.assumeIsolated { observedAtWillChange.append(vm.value) }
        }

        defaults.set(9, forKey: key.name)

        // Poll until the external write has been forwarded.
        var attempts = 0
        while vm.value != 9 && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }

        #expect(vm.value == 9)
        #expect(observedAtWillChange == [0], "the sink must observe the pre-change value")
        _ = cancellable
    }
}

// MARK: - Corrupt external data through the wrapper

@Suite("VMDefaults - Wrapper fallback on corrupt external data")
struct WrapperCorruptExternalDataTests {

    private struct Payload: Codable, Equatable, Sendable { var v: Int }

    @MainActor
    @Test("Corrupt external Codable bytes fall back to the default with one publication and one onError")
    func corruptCodableExternalWriteFallsBack() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Payload>("wrapper-corrupt-codable", default: .init(v: 0), container: defaults)
        let counter = ErrorCounter()

        // Non-default encoder/decoder exercise the wrapper's parameter plumbing end to end.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let vm = OnErrorCodableVM(key, encoder: encoder, decoder: JSONDecoder(), onError: { _ in counter.record() })

        // Diverge from the default first so the fallback is a visible change.
        vm.value = .init(v: 5)
        let stored = try #require(defaults.data(forKey: key.name))
        #expect(try JSONDecoder().decode(Payload.self, from: stored) == .init(v: 5))
        await drainMainActor()
        #expect(counter.count == 0)

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        defaults.set(Data([0xFF]), forKey: key.name) // not valid JSON

        var attempts = 0
        while vm.value != .init(v: 0) && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
        await drainMainActor()

        #expect(vm.value == .init(v: 0), "undecodable external data must fall back to the default")
        #expect(willChanges == 1, "exactly one publication for the fallback change")
        #expect(counter.count == 1, "the wrapper-level onError must report the decode failure once")
        _ = cancellable
    }

    @MainActor
    @Test("External raw type mismatch falls back to the default with one publication")
    func rawTypeMismatchExternalWriteFallsBack() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("wrapper-raw-mismatch", default: 0, container: defaults)
        let vm = ObservableVM(key)

        vm.value = 5
        await drainMainActor()

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        defaults.set("not an int", forKey: key.name)

        var attempts = 0
        while vm.value != 0 && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
        await drainMainActor()

        #expect(vm.value == 0, "a type-mismatched stored value must read back as the default")
        #expect(willChanges == 1)
        _ = cancellable
    }

    @MainActor
    @Test("Undecodable transformed raw value falls back to the default with one publication, then dedupes")
    func undecodableTransformedRawValueFallsBackOnce() async {
        let defaults = makeIsolatedDefaults()
        let vm = ThemePinVM(defaults)

        vm.theme = .dark
        await drainMainActor()

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        defaults.set("chartreuse", forKey: "theme-pin") // not a PinTheme case

        var attempts = 0
        while vm.theme != .system && attempts < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts += 1
        }
        await drainMainActor()

        #expect(vm.theme == .system, "an unknown raw value must fall back to the key's default")
        #expect(willChanges == 1, "exactly one publication for the fallback change")

        // A second corrupt raw value also decodes to the default, which the box already holds —
        // README: "If an external write results in the same value currently held, no publication".
        defaults.set("puce", forKey: "theme-pin")
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)
        await drainMainActor()

        #expect(vm.theme == .system)
        #expect(willChanges == 1, "a fallback equal to the current value must not publish")
        _ = cancellable
    }
}

// MARK: - Encode failure through the wrapper

@Suite("VMDefaults - Wrapper encode failure")
struct WrapperEncodeFailureTests {

    @MainActor
    @Test("A local write whose encode throws reports onError, leaves the store untouched, and holds the new value in memory")
    func encodeFailureLeavesStoreUntouched() async {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<FailingEncodable>("wrapper-encode-fail", default: .init(v: 0), container: defaults)
        let counter = ErrorCounter()
        let vm = OnErrorCodableVM(key, onError: { _ in counter.record() })

        var willChanges = 0
        let cancellable = vm.objectWillChange.sink { _ in willChanges += 1 }

        vm.value = .init(v: 1, explode: true)
        await drainMainActor() // no write landed, so no KVO echo can revert anything

        #expect(counter.count == 1, "the encode failure must be reported through the wrapper's onError")
        #expect(defaults.object(forKey: key.name) == nil, "a failed encode must not write anything")
        #expect(key.get() == .init(v: 0), "the store still reads back as the default")

        // Current behavior, pinned deliberately: the in-memory value keeps the (unpersisted) new
        // value and has already published for it — the property and the store stay diverged until
        // the next external change re-reads the key. If this is ever changed to revert-on-failure,
        // this expectation is the one to flip.
        #expect(vm.value == .init(v: 1, explode: true))
        #expect(willChanges == 1)
        _ = cancellable
    }
}
