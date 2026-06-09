//
//  DefaultsKey.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation

/// Shared read-only interface for both `DefaultsKey` and `CodableDefaultsKey`.
/// Allows writing generic utilities over either key type.
public protocol AnyDefaultsKey {
    var name: String { get }
    var container: UserDefaults { get }
}

/// A strongly-typed UserDefaults key definition.
///
/// Why this exists:
/// - prevents stringly-typed mistakes
/// - couples key name and default value
/// - allows injecting a specific UserDefaults container (suite) for testing
public struct DefaultsKey<Value: PropertyListValue> {
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

extension DefaultsKey: AnyDefaultsKey {}
extension CodableDefaultsKey: AnyDefaultsKey {}

