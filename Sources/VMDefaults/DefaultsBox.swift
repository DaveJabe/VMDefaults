//
//  DefaultsBox.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine

// MARK: - Optional detection (so we can removeObject on nil)

protocol _AnyOptional { var _isNil: Bool { get } }
extension Optional: _AnyOptional { var _isNil: Bool { self == nil } }

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

    /// Coalesces bursts of `UserDefaults.didChangeNotification`.
    private var isRefreshScheduled = false

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

    @objc private func userDefaultsDidChange() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true

        // Hop to the next main-actor turn so multiple notifications collapse into one refresh.
        Task { @MainActor [weak self] in
            self?.coalescedRefresh()
        }
    }

    private func coalescedRefresh() {
        isRefreshScheduled = false
        let latest = read()
        guard latest != value else { return }
        value = latest
    }
}

// MARK: - Raw UserDefaults read/write helpers

@MainActor
func _readRaw<Value>(from defaults: UserDefaults, key: String, defaultValue: Value) -> Value {
    (defaults.object(forKey: key) as? Value) ?? defaultValue
}

@MainActor
func _writeRaw<Value>(to defaults: UserDefaults, key: String, newValue: Value) {
    // Canonical semantics: Optional(nil) removes the key.
    if let opt = newValue as? _AnyOptional, opt._isNil {
        defaults.removeObject(forKey: key)
    } else {
        defaults.set(newValue, forKey: key)
    }
}

