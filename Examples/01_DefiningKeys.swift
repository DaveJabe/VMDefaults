//
//  01_DefiningKeys.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//
// Examples for defining strongly-typed DefaultsKey values

import Foundation
import VMDefaults

// MARK: - Raw keys

// Primitive types
let intKey = DefaultsKey<Int>("examples.int", default: 0)
let boolKey = DefaultsKey<Bool>("examples.bool", default: false)
let doubleKey = DefaultsKey<Double>("examples.double", default: 0.0)

// Optional types (nil removes the key)
let optionalStringKey = DefaultsKey<String?>("examples.optionalString", default: nil)

// MARK: - Codable keys

struct ExampleSettings: Codable, Equatable, Sendable {
    var count: Int
    var name: String
}

let settingsKey = DefaultsKey<ExampleSettings>(
    "examples.settings",
    default: .init(count: 0, name: "zero")
)

// MARK: - Custom container (suite)

// Use a suite to isolate reads/writes from UserDefaults.standard
let examplesSuite = UserDefaults(suiteName: "VMDefaults.Examples")!

let suiteKey = DefaultsKey<String?>(
    "examples.suiteScoped",
    default: nil,
    container: examplesSuite
)
