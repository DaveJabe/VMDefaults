//
//  DefaultsBox.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine


// MARK: - Optional detection (so we can removeObject on nil)

protocol _AnyOptional {
    var _isNil: Bool { get }
    var _unwrapped: Any? { get }
}
extension Optional: _AnyOptional {
    var _isNil: Bool { self == nil }
    // Returns the wrapped value as Any, or nil if absent.
    // Used by _writeRaw to avoid passing Optional<T> to UserDefaults, which is not a valid
    // property list type and causes UserDefaults.standard to silently reject the write.
    var _unwrapped: Any? { self.map { $0 as Any } }
}

// MARK: - Shared box

/// Internal observable box that:
/// - caches the current value
/// - publishes changes
/// - key-value observes its key and re-reads its value when the key changes
///
/// Observation is KVO-based (see `UserDefaultsKeyObservation`): it is suite-scoped (writes
/// through any `UserDefaults` instance of the same suite are seen), cross-process (app-group
/// writes from extensions/widgets are seen), and per-key (writes to other keys do not wake
/// this box). The observed key must be KVC-compliant (no "."); see `UserDefaultsKeyObservation`.
///
/// The `read`/`write` closures allow different storage strategies (raw property-list vs Codable).
@MainActor
final class DefaultsBox<Value: Equatable & Sendable> {
    private let read: @MainActor () -> Value
    private let write: @MainActor (Value) -> Void
    private var observation: UserDefaultsKeyObservation?

    @Published private(set) var value: Value

    #if DEBUG
    /// Set by the wrapper's `ensureBound` once change-forwarding is installed. Used only to emit
    /// a one-time debug warning when an external write refreshes a box whose SwiftUI forwarding
    /// was never activated — the classic "forgot `activateDefaultsBindings()` / `_ = property`"
    /// trap where the value silently updates but SwiftUI never re-renders.
    var hasForwardingBinding = false
    private var didWarnUnbound = false
    #endif

    init(
        container: UserDefaults,
        key: String,
        initialValue: Value,
        read: @escaping @MainActor () -> Value,
        write: @escaping @MainActor (Value) -> Void
    ) {
        self.value = initialValue
        self.read = read
        self.write = write

        self.observation = UserDefaultsKeyObservation(defaults: container, key: key) { [weak self] in
            // KVO delivers synchronously on the writing thread, which may not be the main
            // thread. Hop to the main actor; coalescedRefresh() is idempotent (guard
            // latest != value), so burst changes all resolve to a single value update at most.
            Task { @MainActor [weak self] in self?.coalescedRefresh() }
        }
    }

    // No explicit deinit needed: dropping `observation` invalidates the KVO registration.

    func set(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        write(newValue)
    }

    private func coalescedRefresh() {
        let latest = read()
        guard latest != value else { return }
        value = latest
        #if DEBUG
        if !hasForwardingBinding && !didWarnUnbound {
            didWarnUnbound = true
            print("""
            [VMDefaults] An external UserDefaults write changed a property whose \
            @ObservableUserDefault change-forwarding was never activated, so SwiftUI will not \
            re-render for it. Call `activateDefaultsBindings()` in your view model's init (or read \
            the property once) to enable forwarding. (DEBUG-only; fires at most once per property.)
            """)
        }
        #endif
    }
}

// MARK: - Raw UserDefaults read/write helpers

@MainActor
func _readRaw<Value: PropertyListValue>(from defaults: UserDefaults, key: String, defaultValue: Value) -> Value {
    // The missing-key path must be guarded explicitly: when `Value` is Optional<T> and the
    // key is absent, `nil as? Optional<T>` *succeeds* as `.some(nil)`, so a single-expression
    // `(defaults.object(forKey:) as? Value) ?? defaultValue` would never fall back to a
    // non-nil default for Optional-typed keys.
    guard let object = defaults.object(forKey: key) else { return defaultValue }
    return (object as? Value) ?? defaultValue
}

@MainActor
func _writeRaw<Value: PropertyListValue>(to defaults: UserDefaults, key: String, newValue: Value) {
    if let opt = newValue as? _AnyOptional {
        if opt._isNil {
            defaults.removeObject(forKey: key)
        } else {
            // Unwrap one level before storing: `Optional<T>` is not a valid property list type and
            // UserDefaults silently rejects it. A *single* level is provably sufficient here:
            // `PropertyListValue` only conforms `Optional` where `Wrapped: NonOptionalPropertyListValue`
            // (see PropertyListValue+VMDefaults.swift), so the unwrapped payload is never itself an
            // Optional and is always a valid property-list object.
            defaults.set(opt._unwrapped, forKey: key)
        }
    } else {
        defaults.set(newValue, forKey: key)
    }
}

// MARK: - Codable read/write helpers

/// Decodes the value stored at `key` as JSON, returning `defaultValue` when the key is missing or
/// decoding fails. Decode failures are routed through `onError` (falling back to the global
/// `VMDefaultsCoding.defaultOnError`). Centralizes the read path shared by every Codable accessor
/// and `@ObservableUserDefault` Codable initializer so error-reporting behavior cannot drift.
@MainActor
func _readCodable<Value: Codable>(
    from defaults: UserDefaults,
    key: String,
    defaultValue: Value,
    decoder: JSONDecoder,
    onError: (@Sendable (Error) -> Void)?
) -> Value {
    guard let data = defaults.data(forKey: key) else { return defaultValue }
    do {
        return try decoder.decode(Value.self, from: data)
    } catch {
        (onError ?? VMDefaultsCoding.defaultOnError)?(error)
        return defaultValue
    }
}

/// Encodes `newValue` as JSON and stores it at `key`. An `Optional.none` removes the key (so a
/// missing key reads back as the default). Encode failures are routed through `onError` (falling
/// back to `VMDefaultsCoding.defaultOnError`). Centralizes the write path shared by every Codable
/// accessor and `@ObservableUserDefault` Codable initializer.
@MainActor
func _writeCodable<Value: Codable>(
    to defaults: UserDefaults,
    key: String,
    newValue: Value,
    encoder: JSONEncoder,
    onError: (@Sendable (Error) -> Void)?
) {
    if let opt = newValue as? _AnyOptional, opt._isNil {
        defaults.removeObject(forKey: key)
        return
    }
    do {
        let data = try encoder.encode(newValue)
        defaults.set(data, forKey: key)
    } catch {
        (onError ?? VMDefaultsCoding.defaultOnError)?(error)
    }
}

