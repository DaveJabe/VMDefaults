//
//  DefaultsConvenience.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//

import Foundation

// MARK: - reset() / isStored

// Defined once on the shared `AnyDefaultsKey` protocol so the behavior cannot drift, and so every
// key type (`DefaultsKey`, `CodableDefaultsKey`, `TransformedDefaultsKey`) gets them uniformly.
public extension AnyDefaultsKey {
    /// Removes the stored value for this key from its container, so subsequent reads return the
    /// key's `defaultValue`. Equivalent to `set(.none)` for an Optional key. (`reset` and the
    /// common name `remove` are the same operation here.)
    @MainActor
    func reset() {
        container.removeObject(forKey: name)
    }

    /// Whether a value is currently stored for this key in its container, independent of the
    /// default. `false` after ``reset()`` or before the key is ever written.
    @MainActor
    var isStored: Bool {
        container.object(forKey: name) != nil
    }
}

// MARK: - App-group helper

public extension UserDefaults {
    /// Returns the `UserDefaults` for an app-group suite, or `nil` for a reserved/invalid suite
    /// name (e.g. the main bundle identifier or `NSGlobalDomain`).
    ///
    /// This is a thin, discoverable wrapper over `UserDefaults(suiteName:)` that avoids the
    /// `UserDefaults(suiteName:)!` force-unwrap. Note: a **missing or misconfigured App Groups
    /// entitlement does not return `nil`** — `UserDefaults(suiteName:)` cannot detect that and
    /// instead returns a working-but-privately-backed, non-shared store, so writes silently fail
    /// to reach widgets/extensions. This helper only removes the crash; it cannot validate the
    /// entitlement. Pair with VMDefaults' suite-scoped, cross-process observation:
    ///
    /// ```swift
    /// guard let shared = UserDefaults.appGroup("group.com.example.app") else { return }
    /// let key = DefaultsKey("flag", default: false, container: shared)
    /// ```
    static func appGroup(_ identifier: String) -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
