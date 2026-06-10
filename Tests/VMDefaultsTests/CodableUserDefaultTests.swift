//
//  CodableUserDefaultTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - ObservableUserDefault (Codable)")
struct CodableUserDefaultTests {

    struct Settings: Codable, Equatable, Sendable {
        var count: Int
        var name: String
    }

    @Test("Default value when missing")
    @MainActor
    func defaultValueWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)

        #expect(vm.value == .init(count: 0, name: "zero"))
        #expect(defaults.object(forKey: key.name) == nil)
    }

    @Test("Round-trip local write and read")
    @MainActor
    func roundTripLocalWriteAndRead() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)
        vm.value = .init(count: 3, name: "three")

        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(Settings.self, from: raw)
        #expect(decoded == .init(count: 3, name: "three"))
    }

    @Test("External write updates and publishes")
    @MainActor
    func externalWriteUpdatesAndPublishes() async throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Settings>("settings", default: .init(count: 0, name: "zero"), container: defaults)

        let vm = CodableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        let ext = Settings(count: 9, name: "nine")
        let data = try JSONEncoder().encode(ext)

        defaults.set(data, forKey: key.name)

        #expect(await waiter.value)
        #expect(vm.value == ext)
    }
}
