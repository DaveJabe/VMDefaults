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
///
/// > Important: To use the observation APIs (`publisher()`, `updates()`,
/// > `@ObservableUserDefault`), the key name must be KVC-compliant: it must not contain "."
/// > or start with "@". Observation is KVO-based and silently never fires for such names
/// > (a debug assertion flags them). Plain `get()`/`set()` work with any name.
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

// MARK: - Sendable

// Both key types only hold immutable state: a `String`, a `UserDefaults` reference, and the
// default `Value` — so they are Sendable whenever `Value` is. This lets consumers declare key
// namespaces as plain (non-@MainActor) enums/statics and pass keys across isolation domains.
//
// `@unchecked` justification: `UserDefaults` is not marked Sendable in the SDK, but Apple
// documents it as thread-safe ("The UserDefaults class is thread-safe", NSUserDefaults docs),
// and both key types expose it only via an immutable `let`.
extension DefaultsKey: @unchecked Sendable where Value: Sendable {}
extension CodableDefaultsKey: @unchecked Sendable where Value: Sendable {}

// MARK: - Container rebinding

public extension DefaultsKey {
    /// Returns a copy of this key bound to a different `UserDefaults` container,
    /// preserving its name and default value.
    ///
    /// Useful for dependency injection: production code can use a key defined against
    /// `.standard` (or an app-group suite), while tests rebind the same key to an isolated
    /// `UserDefaults(suiteName:)` instance.
    func with(container: UserDefaults) -> Self {
        Self(name, default: defaultValue, container: container)
    }
}

public extension CodableDefaultsKey {
    /// Returns a copy of this key bound to a different `UserDefaults` container,
    /// preserving its name and default value.
    ///
    /// Useful for dependency injection: production code can use a key defined against
    /// `.standard` (or an app-group suite), while tests rebind the same key to an isolated
    /// `UserDefaults(suiteName:)` instance.
    func with(container: UserDefaults) -> Self {
        Self(name, default: defaultValue, container: container)
    }
}

