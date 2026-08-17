//
//  TransformedStreamsAndRoundTripTests.swift
//  VMDefaults
//
//  Coverage for the remaining audit gaps:
//    - TransformedDefaultsKey.updates()/distinctUpdates(): external writes yield decoded values,
//      unknown raw values yield the default, and the distinct variant dedupes
//    - the custom-transform designated initializer (encode/decode closures, decode-returns-nil
//      fallback) and with(container:) for transformed keys
//    - runtime round-trips for Array/Dictionary/Data/Date values (Foundation bridging through
//      _readRaw) and [Int]? nil-removal, through both DefaultsKey and @ObservableUserDefault
//    - CodableDefaultsKey.debouncedUpdates(for:decoder:onError:): spaced writes each emit, a
//      burst collapses, and cancellation mid-window emits nothing
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

private enum StreamTheme: String, Sendable, Equatable {
    case light, dark, system
}

// MARK: - TransformedDefaultsKey streams

@Suite("VMDefaults - Transformed key streams")
struct TransformedKeyStreamTests {

    @MainActor
    @Test("updates() yields the decoded value for a valid external write and the default for an unknown raw value")
    func updatesYieldsDecodedAndFallback() async {
        let defaults = makeIsolatedDefaults()
        let key = TransformedDefaultsKey(rawRepresentable: "t-stream-updates", default: StreamTheme.system, container: defaults)

        var values: [StreamTheme] = []
        let collector = Task { @MainActor in
            var iterator = key.updates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        // Wait for the initial (default) yield before writing, so yields stay distinct turns.
        var attempts0 = 0
        while values.count < 1 && attempts0 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts0 += 1
        }

        defaults.set("dark", forKey: key.name) // valid raw value → decoded
        var attempts1 = 0
        while values.count < 2 && attempts1 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts1 += 1
        }

        defaults.set("chartreuse", forKey: key.name) // unknown raw value → default fallback
        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [.system, .dark, .system])
    }

    @MainActor
    @Test("distinctUpdates() dedupes consecutive fallbacks to the default")
    func distinctUpdatesDedupesFallbacks() async {
        let defaults = makeIsolatedDefaults()
        let key = TransformedDefaultsKey(rawRepresentable: "t-stream-distinct", default: StreamTheme.system, container: defaults)

        var values: [StreamTheme] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 4 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        var attempts0 = 0
        while values.count < 1 && attempts0 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts0 += 1
        }

        defaults.set("dark", forKey: key.name)
        var attempts1 = 0
        while values.count < 2 && attempts1 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts1 += 1
        }

        defaults.set("chartreuse", forKey: key.name) // unknown → default (distinct from .dark: yields)
        var attempts2 = 0
        while values.count < 3 && attempts2 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts2 += 1
        }

        // A second unknown raw value also decodes to the default — the distinct stream must
        // suppress it (the raw bytes changed, the decoded value did not).
        defaults.set("puce", forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [.system, .dark, .system])
    }
}

// MARK: - Custom transforms

@Suite("VMDefaults - Custom-transform keys")
struct CustomTransformKeyTests {

    /// A lossless custom transform ("v:" prefix) whose decode rejects unprefixed stored values.
    private static func makePrefixedKey(container: UserDefaults) -> TransformedDefaultsKey<String, String> {
        TransformedDefaultsKey(
            name: "custom-prefixed",
            default: "fallback",
            container: container,
            encode: { "v:" + $0 },
            decode: { $0.hasPrefix("v:") ? String($0.dropFirst(2)) : nil }
        )
    }

    @MainActor
    @Test("Custom encode/decode round-trip, and decode-returning-nil falls back to the default")
    func customTransformRoundTripsAndFallsBack() {
        let defaults = makeIsolatedDefaults()
        let key = Self.makePrefixedKey(container: defaults)

        #expect(key.get() == "fallback") // missing key

        key.set("hello")
        #expect(defaults.string(forKey: key.name) == "v:hello", "encode transform must shape the stored representation")
        #expect(key.get() == "hello")

        defaults.set("unprefixed", forKey: key.name) // decode returns nil
        #expect(key.get() == "fallback", "a stored value the transform cannot decode must fall back to the default")
    }

    @MainActor
    @Test("with(container:) preserves the transforms and isolates storage")
    func withContainerPreservesTransforms() {
        let defaultsA = makeIsolatedDefaults()
        let defaultsB = makeIsolatedDefaults()
        let original = Self.makePrefixedKey(container: defaultsA)
        let rebound = original.with(container: defaultsB)

        #expect(rebound.name == original.name)
        #expect(rebound.defaultValue == original.defaultValue)
        #expect(rebound.container === defaultsB)
        #expect(original.container === defaultsA)

        rebound.set("world")
        #expect(defaultsB.string(forKey: rebound.name) == "v:world", "the rebound key must keep the encode transform")
        #expect(rebound.get() == "world")
        #expect(original.get() == "fallback", "writes through the rebound key must not leak into the original container")

        defaultsB.set("unprefixed", forKey: rebound.name)
        #expect(rebound.get() == "fallback", "the rebound key must keep the decode transform (and its nil fallback)")
    }
}

// MARK: - Collection / Data / Date round-trips

@Suite("VMDefaults - Collection & Foundation-type round-trips")
struct CollectionRoundTripTests {

    @MainActor
    @Test("Array, Dictionary, Data, and Date round-trip through DefaultsKey at runtime")
    func foundationTypesRoundTripThroughKeys() {
        let defaults = makeIsolatedDefaults()

        let arrayKey = DefaultsKey<[String]>("rt-array", default: [], container: defaults)
        arrayKey.set(["a", "b"])
        #expect(arrayKey.get() == ["a", "b"])
        #expect(defaults.stringArray(forKey: arrayKey.name) == ["a", "b"])

        let dictKey = DefaultsKey<[String: Int]>("rt-dict", default: [:], container: defaults)
        dictKey.set(["x": 1, "y": 2])
        #expect(dictKey.get() == ["x": 1, "y": 2])

        let dataKey = DefaultsKey<Data>("rt-data", default: Data(), container: defaults)
        dataKey.set(Data([0x01, 0x02, 0x03]))
        #expect(dataKey.get() == Data([0x01, 0x02, 0x03]))

        // A whole-second timestamp survives the property-list round-trip exactly.
        let stamp = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let dateKey = DefaultsKey<Date>("rt-date", default: .distantPast, container: defaults)
        dateKey.set(stamp)
        #expect(dateKey.get() == stamp)
    }

    @MainActor
    @Test("Setting an optional array to nil removes the key and reads back the default")
    func optionalArrayNilRemovalReadsBackDefault() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<[Int]?>("rt-opt-array", default: [9], container: defaults)

        #expect(key.get() == [9]) // missing → non-nil default

        key.set([1, 2])
        #expect(key.get() == [1, 2])
        #expect(defaults.array(forKey: key.name) as? [Int] == [1, 2])

        key.set(nil)
        #expect(defaults.object(forKey: key.name) == nil, "nil must remove the key, not store a null")
        #expect(key.get() == [9], "after removal, reads fall back to the default")
    }

    @MainActor
    @Test("Collections and Foundation types round-trip through @ObservableUserDefault, including external writes")
    func foundationTypesRoundTripThroughWrapper() async {
        let defaults = makeIsolatedDefaults()

        let arrayVM = ObservableVM(DefaultsKey<[String]>("rt-vm-array", default: [], container: defaults))
        arrayVM.value = ["a"]
        #expect(defaults.stringArray(forKey: "rt-vm-array") == ["a"])

        let waiter = startWillChangeWaiter(arrayVM)
        await yieldForSubscriptionInstall()
        defaults.set(["b", "c"], forKey: "rt-vm-array")
        #expect(await waiter.value)
        #expect(arrayVM.value == ["b", "c"], "an NSArray written externally must bridge back into [String]")

        let dictVM = ObservableVM(DefaultsKey<[String: Int]>("rt-vm-dict", default: [:], container: defaults))
        dictVM.value = ["k": 3]
        #expect(dictVM.value == ["k": 3])

        let dataVM = ObservableVM(DefaultsKey<Data>("rt-vm-data", default: Data(), container: defaults))
        dataVM.value = Data([0xAB])
        #expect(dataVM.value == Data([0xAB]))
        #expect(defaults.data(forKey: "rt-vm-data") == Data([0xAB]))

        let stamp = Date(timeIntervalSinceReferenceDate: 700_000_001)
        let dateVM = ObservableVM(DefaultsKey<Date>("rt-vm-date", default: .distantPast, container: defaults))
        dateVM.value = stamp
        #expect(dateVM.value == stamp)
        #expect(defaults.object(forKey: "rt-vm-date") as? Date == stamp)
    }
}

// MARK: - Codable debounce

@Suite("VMDefaults - Codable debounced updates")
struct CodableDebounceTests {

    private struct DPayload: Codable, Equatable, Sendable { var n: Int }

    @MainActor
    @Test("Writes spaced farther apart than the interval each emit")
    func spacedWritesEachEmit() async {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<DPayload>("debounce-codable-spaced", default: .init(n: 0), container: defaults)

        var values: [DPayload] = []
        let collector = Task { @MainActor in
            for await v in key.debouncedUpdates(for: .milliseconds(40), decoder: JSONDecoder()) {
                values.append(v)
                if values.count == 3 { break }
            }
        }

        await yieldForSubscriptionInstall()

        // Wait for each debounced emission before the next write, guaranteeing the writes are
        // spaced beyond the quiet window — every one of them must come through.
        var attempts0 = 0
        while values.count < 1 && attempts0 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts0 += 1
        }

        key.set(.init(n: 1))
        var attempts1 = 0
        while values.count < 2 && attempts1 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts1 += 1
        }

        key.set(.init(n: 2))
        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [.init(n: 0), .init(n: 1), .init(n: 2)])
    }

    @MainActor
    @Test("A rapid burst collapses to the final decoded value")
    func burstCollapsesToFinalValue() async {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<DPayload>("debounce-codable-burst", default: .init(n: 0), container: defaults)

        var values: [DPayload] = []
        let collector = Task { @MainActor in
            for await v in key.debouncedUpdates(for: .milliseconds(40)) {
                values.append(v)
                if v == DPayload(n: 5) { break }
            }
        }

        await yieldForSubscriptionInstall()

        // All five writes land well within one 40ms debounce window.
        for i in 1...5 { key.set(.init(n: i)) }

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values.last == .init(n: 5))
        #expect(values.count < 5, "intermediate burst values must be debounced away")
    }

    @MainActor
    @Test("Cancelling mid-window emits nothing")
    func cancellationMidWindowEmitsNothing() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("debounce-cancel", default: 0, container: defaults)

        var values: [Int] = []
        let collector = Task { @MainActor in
            for await v in key.debouncedUpdates(for: .milliseconds(200)) {
                values.append(v)
            }
        }

        await yieldForSubscriptionInstall()

        key.set(9) // enters the 200ms quiet window...
        collector.cancel() // ...and the consumer walks away before it elapses

        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(values.isEmpty, "no value may be delivered after cancellation, even one already pending")
    }
}
