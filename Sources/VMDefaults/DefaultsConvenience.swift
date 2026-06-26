//
//  DefaultsConvenience.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//

import Foundation

// MARK: - reset() / isStored

public extension DefaultsKey where Value: PropertyListValue {
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

public extension CodableDefaultsKey {
    /// Removes the stored value for this key from its container, so subsequent reads return the
    /// key's `defaultValue`.
    @MainActor
    func reset() {
        container.removeObject(forKey: name)
    }

    /// Whether a value is currently stored for this key in its container, independent of the default.
    @MainActor
    var isStored: Bool {
        container.object(forKey: name) != nil
    }
}

// MARK: - App-group helper

public extension UserDefaults {
    /// Returns the `UserDefaults` for an app-group suite, or `nil` if `identifier` is invalid or
    /// the process lacks the App Groups entitlement for it.
    ///
    /// Prefer this over `UserDefaults(suiteName:)!`: the force-unwrap is a real crash hazard in
    /// extensions/widgets where a misconfigured entitlement returns `nil`. Pair with VMDefaults'
    /// suite-scoped, cross-process observation to share defaults with widgets and extensions:
    ///
    /// ```swift
    /// guard let shared = UserDefaults.appGroup("group.com.example.app") else { return }
    /// let key = DefaultsKey("flag", default: false, container: shared)
    /// ```
    static func appGroup(_ identifier: String) -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
