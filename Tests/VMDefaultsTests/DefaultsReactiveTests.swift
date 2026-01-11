//
//  DefaultsReactiveTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - Non-observable reactive APIs")
struct DefaultsReactiveTests {

    @Test("Raw publisher emits initial and updates, with removeDuplicates")
    @MainActor
    func rawPublisherEmits() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("react.raw", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = key.distinctPublisher().sink { received.append($0) }

        #expect(received == [0])

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        defaults.set(2, forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: 30_000_000)

        let okSequences: [[Int]] = [[0, 1, 2], [0, 2]]
        #expect(okSequences.contains(where: { $0 == received }))

        _ = cancellable
    }

    @Test("Raw async updates emit initial and coalesced changes")
    @MainActor
    func rawAsyncUpdatesEmit() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("react.async.raw", default: nil, container: defaults)

        var values: [String?] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        defaults.set("A", forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set("B", forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(!values.isEmpty)
        #expect(values[0] == nil)
        #expect(values.last == "B")
        #expect(values.count >= 2 && values.count <= 3)
        if values.count == 3 { #expect(values[1] == "A") }
    }

    struct RSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("Codable publisher emits initial and updates")
    @MainActor
    func codablePublisherEmits() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<RSettings>("react.codable.pub", default: .init(count: 0, name: "zero"), container: defaults)

        var received: [RSettings] = []
        let cancellable = key.distinctPublisher().sink { received.append($0) }

        #expect(received == [.init(count: 0, name: "zero")])

        let a = RSettings(count: 1, name: "one")
        let b = RSettings(count: 2, name: "two")
        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
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

        await yieldForSubscriptionInstall()

        let a = RSettings(count: 3, name: "three")
        let b = RSettings(count: 4, name: "four")

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)

        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values.first == .init(count: 0, name: "zero"))
        #expect(values.last == b)
        #expect(values.count >= 2 && values.count <= 3)
        if values.count == 3 { #expect(values[1] == a) }
    }

    // Non-distinct variants

    @Test("Raw publisher emits duplicates when not distinct")
    @MainActor
    func rawPublisherEmitsDuplicatesNonDistinct() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("react.raw.nondist.pub", default: 0, container: defaults)

        var received: [Int] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [0])

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(2, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.first == 0)
        #expect(received.last == 2)
        #expect(received.filter { $0 == 1 }.count >= 2)

        _ = cancellable
    }

    @Test("Raw async updates emit duplicates when not distinct")
    @MainActor
    func rawAsyncUpdatesEmitDuplicatesNonDistinct() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("react.raw.nondist.async", default: 0, container: defaults)

        var values: [Int] = []
        let collector = Task { @MainActor in
            var iterator = key.updates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 4 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(1, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(2, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()
    }

    @Test("Codable publisher emits duplicates when not distinct")
    @MainActor
    func codablePublisherEmitsDuplicatesNonDistinct() async throws {
        struct NDSettings: Codable, Equatable, Sendable { var count: Int; var name: String }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<NDSettings>("react.codable.nondist.pub", default: .init(count: 0, name: "zero"), container: defaults)

        var received: [NDSettings] = []
        let cancellable = key.publisher().sink { received.append($0) }

        #expect(received == [.init(count: 0, name: "zero")])

        let a = NDSettings(count: 1, name: "one")
        let b = NDSettings(count: 2, name: "two")

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(received.first == .init(count: 0, name: "zero"))
        #expect(received.last == b)
        #expect(received.filter { $0 == a }.count >= 2)

        _ = cancellable
    }

    @Test("Codable async updates emit duplicates when not distinct")
    @MainActor
    func codableAsyncUpdatesEmitDuplicatesNonDistinct() async throws {
        struct NDSettings: Codable, Equatable, Sendable { var count: Int; var name: String }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<NDSettings>("react.codable.nondist.async", default: .init(count: 0, name: "zero"), container: defaults)

        var values: [NDSettings] = []
        let collector = Task { @MainActor in
            var iterator = key.updates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 4 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        let a = NDSettings(count: 1, name: "one")
        let b = NDSettings(count: 2, name: "two")

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(a), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        defaults.set(try JSONEncoder().encode(b), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()
    }

    @Test("Raw async distinct updates emit default on nil removal")
    @MainActor
    func rawAsyncDistinctUpdatesEmitDefaultOnNilRemoval() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("react.raw.opt.nil", default: nil, container: defaults)
        var values: [String?] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        defaults.set("X", forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        // Wait until the first update ("X") is observed to avoid coalescing with the removal.
        var attempts1 = 0
        while values.count < 2 && attempts1 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts1 += 1
        }

        defaults.removeObject(forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        // Wait until the removal (default) is observed as the third value.
        var attempts2 = 0
        while values.count < 3 && attempts2 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts2 += 1
        }

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [nil, "X", nil])
    }

    @Test("Codable async distinct updates emit default on nil removal")
    @MainActor
    func codableAsyncDistinctUpdatesEmitDefaultOnNilRemoval() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<String?>("react.codable.opt.nil", default: nil, container: defaults)

        var values: [String?] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 3 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()
        try? await Task.sleep(nanoseconds: propagationDelayNanos * 3)

        let some = try JSONEncoder().encode(Optional<String>.some("X"))
        defaults.set(some, forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        // Wait until the first update ("X") is observed to avoid coalescing with the removal.
        var attempts1 = 0
        while values.count < 2 && attempts1 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts1 += 1
        }

        defaults.removeObject(forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        // Wait until the removal (default) is observed as the third value.
        var attempts2 = 0
        while values.count < 3 && attempts2 < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            attempts2 += 1
        }

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [nil, "X", nil])
    }

    @Test("Raw async updates ignore other container notifications")
    @MainActor
    func rawAsyncUpdatesIgnoreOtherContainerNotifications() async {
        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)!
        let key = DefaultsKey<Int>("react.scope.raw", default: 0, container: defaultsA)

        var values: [Int] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 2 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        defaultsB.set(1, forKey: key.name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaultsB)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [0])
    }

    @Test("Codable async updates ignore other container notifications")
    @MainActor
    func codableAsyncUpdatesIgnoreOtherContainerNotifications() async throws {
        struct S: Codable, Equatable, Sendable { var count: Int; var name: String }

        let suite = "VMDefaultsTests.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suite)!
        let defaultsB = UserDefaults(suiteName: suite)!
        let key = CodableDefaultsKey<S>("react.scope.codable", default: .init(count: 0, name: "zero"), container: defaultsA)

        var values: [S] = []
        let collector = Task { @MainActor in
            var iterator = key.distinctUpdates().makeAsyncIterator()
            while !Task.isCancelled && values.count < 2 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        let a = S(count: 1, name: "one")
        let data = try JSONEncoder().encode(a)
        defaultsB.set(data, forKey: key.name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaultsB)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(values == [.init(count: 0, name: "zero")])
    }

    @Test("Codable publisher on decode error emits default and calls onError")
    @MainActor
    func codablePublisherDecodeErrorEmitsDefaultAndCallsOnError() async {
        struct S: Codable, Equatable, Sendable { var v: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("react.codable.error.pub", default: .init(v: 0), container: defaults)

        final class ErrorBox: @unchecked Sendable { var value: Error? }
        let box = ErrorBox()
        var received: [S] = []
        let cancellable = key.publisher(onError: { box.value = $0 }).sink { received.append($0) }

        #expect(received == [.init(v: 0)])

        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        #expect(box.value != nil)
        #expect(received.last == .init(v: 0))
        #expect(received.filter { $0 == .init(v: 0) }.count >= 2)

        _ = cancellable
    }

    @Test("Codable async updates on decode error emit default and call onError")
    @MainActor
    func codableAsyncUpdatesDecodeErrorEmitsDefaultAndCallsOnError() async {
        struct S: Codable, Equatable, Sendable { var v: Int }
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<S>("react.codable.error.async", default: .init(v: 0), container: defaults)

        final class ErrorBox: @unchecked Sendable { var value: Error? }
        let box = ErrorBox()

        var values: [S] = []
        let collector = Task { @MainActor in
            var iterator = key.updates(onError: { box.value = $0 }).makeAsyncIterator()
            while !Task.isCancelled && values.count < 2 {
                if let next = await iterator.next() { values.append(next) }
            }
        }

        await yieldForSubscriptionInstall()

        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        postDidChange(for: defaults)
        try? await Task.sleep(nanoseconds: propagationDelayNanos)

        let fallback = Task { @MainActor in
            try? await Task.sleep(nanoseconds: willChangeTimeoutNanos)
            collector.cancel()
        }
        await collector.value
        fallback.cancel()

        #expect(box.value != nil)
        #expect(values.last == .init(v: 0))
        #expect(values.filter { $0 == .init(v: 0) }.count >= 2)
    }
  
}

