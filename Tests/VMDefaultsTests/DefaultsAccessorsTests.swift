//
//  DefaultsAccessorsTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - Non-observable accessors")
struct DefaultsAccessorsTests {

    @Test("get() returns default when missing")
    @MainActor
    func getReturnsDefaultWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("plain.missing", default: 42, container: defaults)

        #expect(key.get() == 42)
    }

    @Test("get() returns stored raw value")
    @MainActor
    func getReturnsStoredRawValue() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("plain.raw", default: nil, container: defaults)

        defaults.set("hello", forKey: key.name)
        #expect(key.get() == "hello")
    }

    struct ASettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("get() returns default when missing or invalid")
    @MainActor
    func getCodableReturnsDefaultWhenMissingOrInvalid() {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<ASettings>("plain.codable.invalid", default: .init(count: 0, name: "zero"), container: defaults)

        #expect(key.get() == .init(count: 0, name: "zero"))

        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: key.name)
        #expect(key.get() == .init(count: 0, name: "zero"))
    }

    @Test("get() returns decoded value")
    @MainActor
    func getCodableReturnsDecodedValue() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<ASettings>("plain.codable.valid", default: .init(count: 0, name: "zero"), container: defaults)

        let payload = ASettings(count: 7, name: "seven")
        let data = try JSONEncoder().encode(payload)
        defaults.set(data, forKey: key.name)

        #expect(key.get() == payload)
    }
}

@Suite("VMDefaults - Non-observable accessors (set)")
struct DefaultsAccessorsSetTests {

    struct SASettings: Codable, Equatable, Sendable { var count: Int; var name: String }

    @Test("set() stores raw value")
    @MainActor
    func setRawStoresValue() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<Int>("plain.raw.set", default: 0, container: defaults)
        key.set(7)
        #expect(defaults.integer(forKey: key.name) == 7)
    }

    @Test("set(nil) removes key - Raw Optional")
    @MainActor
    func setRawOptionalNilRemovesKey() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("plain.raw.opt.set", default: nil, container: defaults)
        key.set("X")
        #expect(defaults.string(forKey: key.name) == "X")
        key.set(nil)
        #expect(defaults.object(forKey: key.name) == nil)
        #expect(key.get() == nil)
    }

    @Test("set() encodes and stores Codable value")
    @MainActor
    func setCodableStoresEncodedValue() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<SASettings>("plain.codable.set", default: .init(count: 0, name: "zero"), container: defaults)
        let payload = SASettings(count: 5, name: "five")
        key.set(payload)
        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(SASettings.self, from: raw)
        #expect(decoded == payload)
    }

    @Test("set(nil) removes key - Codable Optional")
    @MainActor
    func setCodableOptionalNilRemovesKey() throws {
        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<String?>("plain.codable.opt.set", default: nil, container: defaults)
        key.set("Hello")
        let raw = try #require(defaults.data(forKey: key.name))
        let decoded = try JSONDecoder().decode(Optional<String>.self, from: raw)
        #expect(decoded == "Hello")
        key.set(nil)
        #expect(defaults.object(forKey: key.name) == nil)
        #expect(key.get() == nil)
    }

    @Test("set() encoding error calls onError and does not write")
    @MainActor
    func setCodableEncodingErrorCallsOnError() {
        struct Failing: Codable, Equatable, Sendable {
            var v: Int
            enum E: Error { case boom }
            init(v: Int) { self.v = v }
            func encode(to encoder: Encoder) throws { throw E.boom }
            init(from decoder: Decoder) throws { self.v = 0 }
        }

        let defaults = makeIsolatedDefaults()
        let key = CodableDefaultsKey<Failing>("plain.codable.fail.set", default: .init(v: 0), container: defaults)
        final class ErrorBox: @unchecked Sendable { var value: Error? }
        let box = ErrorBox()
        key.set(.init(v: 1), onError: { box.value = $0 })
        #expect(box.value != nil)
        #expect(defaults.object(forKey: key.name) == nil)
    }
}

