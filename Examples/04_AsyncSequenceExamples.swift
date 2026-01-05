//
//  04_AsyncSequenceExamples.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//
// Examples showing AsyncSequence updates with VMDefaults

import Foundation
import VMDefaults

let asyncSuite = UserDefaults(suiteName: "VMDefaults.Examples.Async")!
let asyncRawKey = DefaultsKey<String?>("async.raw", default: nil, container: asyncSuite)

struct AsyncSettings: Codable, Equatable, Sendable { var count: Int; var name: String }
let asyncCodableKey = DefaultsKey<AsyncSettings>(
    "async.codable",
    default: .init(count: 0, name: "zero"),
    container: asyncSuite
)

@MainActor
func demoAsyncRawUpdates() async {
    var iterator = asyncRawKey.distinctUpdates().makeAsyncIterator()

    // Kick off a producer in the background (simulated external writes)
    Task { @Sendable in
        try? await Task.sleep(nanoseconds: 10_000_000)
        asyncSuite.set("A", forKey: asyncRawKey.name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: asyncSuite)

        try? await Task.sleep(nanoseconds: 10_000_000)
        asyncSuite.set("A", forKey: asyncRawKey.name) // duplicate should be coalesced/ignored by distinctUpdates
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: asyncSuite)

        try? await Task.sleep(nanoseconds: 10_000_000)
        asyncSuite.set("B", forKey: asyncRawKey.name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: asyncSuite)
    }

    // Read three values: initial nil, then A, then B
    for _ in 0..<3 {
        if let next = await iterator.next() {
            print("[Async Raw] ->", String(describing: next))
        }
    }
}

@MainActor
func demoAsyncCodableUpdates() async {
    var iterator = asyncCodableKey.distinctUpdates().makeAsyncIterator()

    Task { @Sendable in
        let a = AsyncSettings(count: 1, name: "one")
        let b = AsyncSettings(count: 2, name: "two")
        try? await Task.sleep(nanoseconds: 10_000_000)
        if let data = try? JSONEncoder().encode(a) {
            asyncSuite.set(data, forKey: asyncCodableKey.name)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: asyncSuite)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        if let data = try? JSONEncoder().encode(b) {
            asyncSuite.set(data, forKey: asyncCodableKey.name)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: asyncSuite)
        }
    }

    // Read three values: initial default, then a, then b
    for _ in 0..<3 {
        if let next = await iterator.next() {
            print("[Async Codable] ->", next)
        }
    }
}
