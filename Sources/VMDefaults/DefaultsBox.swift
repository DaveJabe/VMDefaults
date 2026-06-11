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
            // Unwrap before storing: Optional<T> is not a valid property list type.
            // UserDefaults.standard silently rejects Optional wrappers without unwrapping.
            defaults.set(opt._unwrapped, forKey: key)
        }
    } else {
        defaults.set(newValue, forKey: key)
    }
}

