//
// 02_NonObservableAccessors.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//
// Examples showing non-observable accessors

import Foundation
import VMDefaults

// Use an isolated suite so we don't write to UserDefaults.standard in examples.
let nonObsSuite = UserDefaults(suiteName: "VMDefaults.Examples.NonObs")!

let rawKey = DefaultsKey<Int>("nonobs-raw", default: 42, container: nonObsSuite)
let optKey = DefaultsKey<String?>("nonobs-opt", default: nil, container: nonObsSuite)

struct NonObsSettings: Codable, Equatable, Sendable { var count: Int; var name: String }
let codableKey = CodableDefaultsKey<NonObsSettings>(
    "nonobs-codable",
    default: .init(count: 0, name: "zero"),
    container: nonObsSuite
)

@MainActor
func demoNonObservableAccessors() {
    // Raw get(): returns default when missing
    let a = rawKey.get() // 42
    print("raw default:", a)

    // Write a raw value and read back
    nonObsSuite.set(7, forKey: rawKey.name)
    let b = rawKey.get() // 7
    print("raw stored:", b)

    // Optional raw: nil default, then write/remove
    let c = optKey.get() // nil
    print("optional default:", c as Any)
    nonObsSuite.set("Hello", forKey: optKey.name)
    let d = optKey.get() // "Hello"
    print("optional stored:", d as Any)

    // Codable get(): missing -> default
    let e = codableKey.get() // .init(count:0, name:"zero")
    print("codable default:", e)

    // Store valid JSON-encoded data and read back
    let payload = NonObsSettings(count: 3, name: "three")
    if let data = try? JSONEncoder().encode(payload) {
        nonObsSuite.set(data, forKey: codableKey.name)
    }
    let f = codableKey.get() // payload
    print("codable stored:", f)
}

