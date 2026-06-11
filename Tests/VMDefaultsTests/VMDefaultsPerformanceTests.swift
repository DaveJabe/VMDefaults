//
//  VMDefaultsPerformanceTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - Performance")
struct VMDefaultsPerformanceTests {

    @Test("Bulk sequential local writes and reads - Observable")
    @MainActor
    func bulkSequentialLocalWritesReadsObservable() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("perf-int-local", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 2_000
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations { vm.value = i }

        let writeDuration = start.duration(to: clock.now)

        #expect(vm.value == iterations)
        #expect(defaults.integer(forKey: key.name) == iterations)

        var sum = 0
        for _ in 0..<iterations { sum += vm.value }
        #expect(sum >= iterations)

        print("[Perf][Observable] local writes: \(writeDuration)")
    }

    @Test("Bulk sequential external writes - Observable")
    @MainActor
    func bulkSequentialExternalWritesObservable() async throws {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("perf-int-external", default: 0, container: defaults)
        let vm = ObservableVM(key)

        let iterations = 1_000
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations {
            defaults.set(i, forKey: key.name)
        }

        let duration = start.duration(to: clock.now)

        try await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(vm.value == iterations)

        print("[Perf][Observable] external writes: \(duration)")
    }

    struct PSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("Bulk sequential local writes and reads - Codable")
    @MainActor
    func bulkSequentialLocalWritesReadsCodable() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<PSettings>("perf-codable-local", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let iterations = 500
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations { vm.value = .init(count: i, name: "n\(i)") }

        let writeDuration = start.duration(to: clock.now)

        #expect(vm.value == .init(count: iterations, name: "n\(iterations)"))

        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(PSettings.self, from: raw)
        #expect(decoded == .init(count: iterations, name: "n\(iterations)"))

        print("[Perf][Codable] local writes: \(writeDuration)")
    }

    @Test("Bulk sequential external writes - Codable")
    @MainActor
    func bulkSequentialExternalWritesCodable() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<PSettings>("perf-codable-external", default: .init(count: 0, name: "zero"), container: defaults)
        let vm = CodableVM(key)

        let iterations = 300
        let clock = ContinuousClock()
        let start = clock.now

        for i in 1...iterations {
            let payload = PSettings(count: i, name: "n\(i)")
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: key.name)
        }

        let duration = start.duration(to: clock.now)

        try await Task.sleep(nanoseconds: propagationDelayNanos)
        #expect(vm.value == .init(count: iterations, name: "n\(iterations)"))

        print("[Perf][Codable] external writes: \(duration)")
    }
}
