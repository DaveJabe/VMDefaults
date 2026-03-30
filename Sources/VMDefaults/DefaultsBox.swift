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

    @objc nonisolated private func userDefaultsDidChange() {
        // NotificationCenter delivers on the posting thread, which may not be the main thread.
        // Hop to the main actor and coalesce there where isRefreshScheduled is safe to access.
        Task { @MainActor [weak self] in
            guard let self, !self.isRefreshScheduled else { return }
            self.isRefreshScheduled = true
            self.coalescedRefresh()
        }
    }

    private func coalescedRefresh() {
        defer { isRefreshScheduled = false }
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
    // Canonical semantics: Optional(nil) removes the key.
    if let opt = newValue as? _AnyOptional, opt._isNil {
        defaults.removeObject(forKey: key)
    } else {
        // Although constrained to PropertyListValue, we rely on the dynamic UserDefaults semantics here.
        defaults.set(newValue, forKey: key)
    }
}

