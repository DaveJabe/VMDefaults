//
//  DefaultsKey.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation

/// A strongly-typed UserDefaults key definition.
///
/// Why this exists:
/// - prevents stringly-typed mistakes
/// - couples key name and default value
/// - allows injecting a specific UserDefaults container (suite) for testing
public struct DefaultsKey<Value> {
    public let name: String
    public let defaultValue: Value
    public let container: UserDefaults

    public init(_ name: String, default defaultValue: Value, container: UserDefaults = .standard) {
        self.name = name
        self.defaultValue = defaultValue
        self.container = container
    }
}

public struct CodableDefaultsKey<Value: Codable> {
    public let name: String
    public let defaultValue: Value
    public let container: UserDefaults
    public init(_ name: String, default defaultValue: Value, container: UserDefaults = .standard) {
        self.name = name
        self.defaultValue = defaultValue
        self.container = container
    }
}

