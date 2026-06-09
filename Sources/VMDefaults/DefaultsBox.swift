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
/// - listens to `UserDefaults.didChangeNotification` and re-reads its value
///
/// The `read`/`write` closures allow different storage strategies (raw property-list vs Codable).
@MainActor
final class DefaultsBox<Value: Equatable & Sendable> {
    private let container: UserDefaults
    private let read: @MainActor () -> Value
    private let write: @MainActor (Value) -> Void

    @Published private(set) var value: Value

    init(
        container: UserDefaults,
        initialValue: Value,
        read: @escaping @MainActor () -> Value,
        write: @escaping @MainActor (Value) -> Void
    ) {
        self.container = container
        self.value = initialValue
        self.read = read
        self.write = write

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: container
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func set(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        write(newValue)
    }

    @objc nonisolated private func userDefaultsDidChange() {
        // NotificationCenter delivers on the posting thread, which may not be the main thread.
        // Hop to the main actor; coalescedRefresh() is idempotent (guard latest != value),
        // so burst notifications all resolve to a single value update at most.
        Task { @MainActor [weak self] in self?.coalescedRefresh() }
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
    (defaults.object(forKey: key) as? Value) ?? defaultValue
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

