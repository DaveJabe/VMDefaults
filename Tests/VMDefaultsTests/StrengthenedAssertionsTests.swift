//
//  StrengthenedAssertionsTests.swift
//  VMDefaults
//
//  Tightens assertions the audit flagged as too loose: onError invocation *counts* (not just
//  existence), deterministic burst coalescing, the dotted-key KVC predicate, the global
//  defaultOnError fallback, and the effect of cancelling a publisher subscription.
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

// MARK: - onError invocation counts

@Suite("VMDefaults - onError invocation counts")
struct OnErrorCountTests {

    private struct S: Codable, Equatable, Sendable { var v: Int }

    @MainActor
    @Test("get() calls onError exactly once per corrupt read")
    func getCallsOnErrorOncePerRead() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("err-count-get", default: .init(v: 0), container: defaults)
        let counter = ErrorCounter()

        defaults.set(Data([0xFF, 0x00]), forKey: key.name) // not valid JSON

        _ = key.get(onError: { _ in counter.record() })
        #expect(counter.count == 1)

        _ = key.get(onError: { _ in counter.record() })
        #expect(counter.count == 2) // one per read, no hidden extra reporting
    }

    @MainActor
    @Test("Initial read of a corrupt key reports through updates() onError (no silent swallow)")
    func updatesInitialReadReportsError() async {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("err-count-initial", default: .init(v: 0), container: defaults)
        let counter = ErrorCounter()

        // Corrupt data present BEFORE subscription — exercises the initial read specifically.
        defaults.set(Data([0xFF, 0x00]), forKey: key.name)

        var first: S?
        let collector = Task { @MainActor in
            for await v in key.updates(onError: { _ in counter.record() }) {
                first = v
                break // we only care about the initial emission
            }
        }
        await collector.value

        #expect(first == .init(v: 0))  // falls back to default
        #expect(counter.count == 1)    // and the initial decode failure WAS reported (regression guard)
    }
}

// MARK: - Global defaultOnError fallback

@Suite("VMDefaults - global defaultOnError fallback")
struct DefaultOnErrorFallbackTests {

    private struct S: Codable, Equatable, Sendable { var v: Int }

    @MainActor
    @Test("defaultOnError is used when no per-call handler is provided")
    func globalFallbackFires() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("err-global", default: .init(v: 0), container: defaults)
        let counter = ErrorCounter()

        let previous = VMDefaultsCoding.defaultOnError
        defer { VMDefaultsCoding.defaultOnError = previous } // restore: this is process-global state
        VMDefaultsCoding.defaultOnError = { _ in counter.record() }

        defaults.set(Data([0xFF, 0x00]), forKey: key.name)
        _ = key.get() // no per-call onError → must fall through to the global handler
        #expect(counter.count == 1)
    }
}

// MARK: - Deterministic burst coalescing

@Suite("VMDefaults - Deterministic coalescing")
struct DeterministicCoalescingTests {

    @MainActor
    @Test("A synchronous burst within one runloop turn coalesces to the final value")
    func synchronousBurstCoalesces() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("coalesce-det", default: 0, container: defaults)

        var values: [Int] = []
        let collector = Task { @MainActor in
            var iterator = key.updates().makeAsyncIterator()      // non-distinct
            while !Task.isCancelled && values.count < 2 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()
        // Five writes with NO suspension between them: they share one runloop turn, so the
        // bufferingNewest(1) source + Task.yield collapse them into a single re-read of the latest.
        for i in 1...5 { defaults.set(i, forKey: key.name) }

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        // Initial 0, then exactly one coalesced emission of the final value 5 — never 1/2/3/4.
        #expect(values == [0, 5])
    }
}

// MARK: - KVC predicate

@Suite("VMDefaults - KVC observability predicate")
struct KVCPredicateTests {

    @Test("isKVCObservable rejects dotted and @-prefixed keys, accepts the rest")
    func predicateClassifiesKeys() {
        #expect(UserDefaultsKeyObservation.isKVCObservable("feature-flag"))
        #expect(UserDefaultsKeyObservation.isKVCObservable("launch_count"))
        #expect(UserDefaultsKeyObservation.isKVCObservable("plainKey123"))
        #expect(UserDefaultsKeyObservation.isKVCObservable("a.b") == false)     // nested key path
        #expect(UserDefaultsKeyObservation.isKVCObservable("com.example.flag") == false)
        #expect(UserDefaultsKeyObservation.isKVCObservable("@count") == false)  // collection operator
    }
}

// MARK: - Cancellation effect

@Suite("VMDefaults - Subscription cancellation")
struct CancellationTests {

    @MainActor
    @Test("Cancelling a publisher subscription stops further emissions")
    func cancellationStopsEmissions() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("cancel-pub", default: 0, container: defaults)

        var received: [Int] = []
        var cancellable: AnyCancellable? = key.publisher().sink { received.append($0) }
        #expect(received == [0])

        // One live update gets through.
        defaults.set(1, forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(received.contains(1))

        // Cancel, then write again: no further emission may arrive.
        cancellable?.cancel()
        cancellable = nil
        let countAtCancel = received.count

        defaults.set(2, forKey: key.name)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(received.count == countAtCancel)
        #expect(received.contains(2) == false)
    }
}
