//
//  VMDefaultsConcurrencyTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - Concurrency")
struct VMDefaultsConcurrencyTests {

    @Test("Concurrent external writes - Observable")
    @MainActor
    func concurrentExternalWritesObservable() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("conc.observable", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let values = (0..<50).map { "V\($0)" }

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
        let key = CodableDefaultsKey<CSettings>("conc.codable", default: .init(count: 0, name: "zero"), container: defaults)
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
        let key = CodableDefaultsKey<MSettings>("conc.mixed.codable", default: .init(count: 0, name: "zero"), container: defaults)
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
