//
//  CompileTimeGuards.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//
//  This file documents compile-time guarantees that are intentionally not enforceable
//  via runtime tests. The #if false block below contains code that should not compile
//  if DefaultsKey is correctly constrained to PropertyListValue and does not support Codable.
//

import Foundation
import Testing
@testable import VMDefaults

@Suite("VMDefaults - Compile-time Guards")
struct CompileTimeGuards {
    @Test("DefaultsKey refuses Codable at compile time (documentation-only)")
    func defaultsKeyRefusesCodable() async throws {
        // This test intentionally does nothing at runtime. It exists to accompany
        // the #if false block below that contains code which should fail to compile
        // if uncommented, demonstrating the intended constraint.
        #expect(Bool(true))
    }
}

// POSITIVE guards — these are real, compiled top-level declarations (global `let`s are type-checked
// regardless of use). They fail the build if a future edit regresses conformance for a *supported*
// shape: a top-level Optional, a nested non-optional collection, or an optional-of-collection.
let okOptional = DefaultsKey<Int?>("ok-optional", default: nil)
let okNestedArray = DefaultsKey<[[Int]]>("ok-nested-array", default: [])
let okOptionalArray = DefaultsKey<[Int]?>("ok-optional-array", default: nil)
let okDictOfArray = DefaultsKey<[String: [Int]]>("ok-dict-of-array", default: [:])

// The following code intentionally does not compile and is wrapped in #if false.
// It documents that DefaultsKey is restricted to PropertyListValue and cannot be
// used with Codable types, and that there is no ObservableUserDefault initializer
// that accepts a DefaultsKey where Value: Codable.
#if false
import Combine

struct CTSettings: Codable, Equatable, Sendable { var count: Int; var name: String }

// This should fail: DefaultsKey does not accept Codable types.
let badKey = DefaultsKey<CTSettings>(
    "compile-fail-defaultskey-codable",
    default: .init(count: 0, name: "zero")
)

// This should fail: ObservableUserDefault.wrappedValue is @available(*, unavailable), so the
// wrapper cannot be used outside an ObservableObject class (e.g. on a struct property or a
// local variable). Previously this was a reachable runtime fatalError; it is now a compile error.
struct BadStruct {
    @ObservableUserDefault var value: Int

    init() {
        _value = ObservableUserDefault(DefaultsKey<Int>("compile-fail-struct", default: 0))
    }
}

// This should also fail: direct wrappedValue access is unavailable.
@MainActor
func badDirectWrappedValueAccess() {
    let wrapper = ObservableUserDefault(DefaultsKey<Int>("compile-fail-direct", default: 0))
    _ = wrapper.wrappedValue
}

// This should also fail: there is no ObservableUserDefault init for DefaultsKey<Codable>.
@MainActor
final class BadVM: ObservableObject {
    @ObservableUserDefault var value: CTSettings

    init() {
        // No such initializer; should not compile if DefaultsKey is correctly constrained.
        _value = ObservableUserDefault(
            DefaultsKey<CTSettings>(
                "x",
                default: .init(count: 0, name: "zero")
            )
        )
    }
}

// These should fail: collection-of-optional and nested-optional shapes are *not*
// PropertyListValue. They compile under a naive `Element: PropertyListValue` bound but write a
// property list containing a null, which CoreFoundation rejects with abort(). Constraining
// collection elements to `NonOptionalPropertyListValue` turns them into compile errors.
// Error: "requires that 'Int?' conform to 'NonOptionalPropertyListValue'".
// These collection-of-optional / nested-optional shapes must NOT compile (they would store a null
// and abort CoreFoundation). The positive counterparts are compiled at top level above.
let badArrayOfOptional = DefaultsKey<[Int?]>("compile-fail-array-optional", default: [])
let badDictOfOptional = DefaultsKey<[String: Int?]>("compile-fail-dict-optional", default: [:])
let badNestedOptional = DefaultsKey<Int??>("compile-fail-nested-optional", default: nil)
#endif
