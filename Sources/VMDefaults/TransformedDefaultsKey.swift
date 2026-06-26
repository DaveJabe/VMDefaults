//
//  TransformedDefaultsKey.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//

import Foundation

/// A key that persists a value which is **not** itself a property-list type by transforming it
/// to/from a property-list `Stored` representation.
///
/// This powers raw storage of common non-property-list types without paying the JSON-blob cost of
/// `CodableDefaultsKey`:
/// - `RawRepresentable` enums (stored as their `rawValue`) — see ``init(rawRepresentable:default:container:)``
/// - `URL` (stored as `absoluteString`) — see ``init(url:default:container:)``
/// - `UUID` (stored as `uuidString`) — see ``init(uuid:default:container:)``
///
/// You can also supply your own `encode`/`decode` transforms for any `Value`. `decode` returns an
/// optional: when it returns `nil` (e.g. a stored raw value no longer maps to any enum case), the
/// key's `defaultValue` is used.
///
/// > Note: The stored representation here (a raw scalar/string) is intentionally simple and human-
/// > readable, but it is **not** the archived format `@AppStorage` uses for `URL`. If you need to
/// > share a value with `@AppStorage`, match its representation yourself via a custom transform.
public struct TransformedDefaultsKey<Value: Sendable, Stored: PropertyListValue & Sendable>: AnyDefaultsKey, @unchecked Sendable {
    // @unchecked Sendable justification: identical to `DefaultsKey` — only immutable state is held
    // (`String`, the default `Value`, two `@Sendable` closures, and a thread-safe `UserDefaults`
    // exposed via an immutable `let`).
    public let name: String
    public let defaultValue: Value
    public let container: UserDefaults
    let encode: @Sendable (Value) -> Stored
    let decode: @Sendable (Stored) -> Value?

    public init(
        name: String,
        default defaultValue: Value,
        container: UserDefaults = .standard,
        encode: @escaping @Sendable (Value) -> Stored,
        decode: @escaping @Sendable (Stored) -> Value?
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.container = container
        self.encode = encode
        self.decode = decode
    }

    /// Returns a copy of this key bound to a different `UserDefaults` container, preserving its
    /// name, default value, and transforms.
    public func with(container: UserDefaults) -> Self {
        Self(name: name, default: defaultValue, container: container, encode: encode, decode: decode)
    }
}

// MARK: - Convenience constructors

public extension TransformedDefaultsKey where Value: RawRepresentable, Value.RawValue == Stored {
    /// A key for a `RawRepresentable` value (e.g. a `String`- or `Int`-backed enum), stored as its
    /// raw value so it round-trips as a native property-list type.
    init(rawRepresentable name: String, default defaultValue: Value, container: UserDefaults = .standard) {
        self.init(
            name: name,
            default: defaultValue,
            container: container,
            encode: { $0.rawValue },
            decode: { Value(rawValue: $0) }
        )
    }
}

public extension TransformedDefaultsKey where Value == URL, Stored == String {
    /// A key for a `URL`, stored as its `absoluteString`.
    init(url name: String, default defaultValue: URL, container: UserDefaults = .standard) {
        self.init(
            name: name,
            default: defaultValue,
            container: container,
            encode: { $0.absoluteString },
            decode: { URL(string: $0) }
        )
    }
}

public extension TransformedDefaultsKey where Value == UUID, Stored == String {
    /// A key for a `UUID`, stored as its `uuidString`.
    init(uuid name: String, default defaultValue: UUID, container: UserDefaults = .standard) {
        self.init(
            name: name,
            default: defaultValue,
            container: container,
            encode: { $0.uuidString },
            decode: { UUID(uuidString: $0) }
        )
    }
}

// MARK: - Non-observable accessors

public extension TransformedDefaultsKey {
    /// Returns the current value for this key, decoded from its stored representation, or the key's
    /// default if missing or if the stored representation no longer decodes.
    @MainActor
    func get() -> Value {
        guard container.object(forKey: name) != nil else { return defaultValue }
        let stored = _readRaw(from: container, key: name, defaultValue: encode(defaultValue))
        return decode(stored) ?? defaultValue
    }

    /// Encodes `value` to its stored representation and persists it.
    @MainActor
    func set(_ value: Value) {
        _writeRaw(to: container, key: name, newValue: encode(value))
    }

    /// Removes the stored value, so subsequent reads return the key's `defaultValue`.
    @MainActor
    func reset() {
        container.removeObject(forKey: name)
    }
}

public extension TransformedDefaultsKey where Value: Sendable {
    /// An `AsyncStream` that yields the current value and subsequent updates for this key.
    /// Bursts are coalesced to one yield per runloop turn. KVO-based: suite-scoped, cross-process,
    /// per-key; the key name must be KVC-compliant.
    @MainActor
    func updates() -> AsyncStream<Value> {
        let key = self
        return _coalescedStream(in: container, key: name, read: { key.get() })
    }
}

public extension TransformedDefaultsKey where Value: Equatable & Sendable {
    /// An `AsyncStream` that yields only when the decoded value actually changes.
    @MainActor
    func distinctUpdates() -> AsyncStream<Value> {
        let key = self
        return _coalescedStream(in: container, key: name, read: { key.get() }, isDuplicate: { $0 == $1 })
    }
}
