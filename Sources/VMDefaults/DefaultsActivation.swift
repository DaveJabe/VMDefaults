//
//  DefaultsActivation.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//

import Foundation
import Combine

/// Internal hook letting ``activateDefaultsBindings()`` install an `@ObservableUserDefault`'s
/// change-forwarding without knowing the wrapper's `Value` type. `ObservableUserDefault` conforms;
/// the reflection loop casts each stored wrapper to this protocol and calls `_activate(on:)`.
@MainActor
protocol _DefaultsActivatable {
    func _activate<O: ObservableObject>(on instance: O)
    where O.ObjectWillChangePublisher == ObservableObjectPublisher
}

public extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// Eagerly installs the change-forwarding bindings for every `@ObservableUserDefault` property
    /// on this object, so external `UserDefaults` writes (from another view model, another
    /// `UserDefaults` instance of the same suite, or another process sharing an app-group suite)
    /// refresh SwiftUI even for properties that are never read directly.
    ///
    /// Call this once at the end of your view model's `init`:
    ///
    /// ```swift
    /// @MainActor
    /// final class SettingsVM: ObservableObject {
    ///     @ObservableUserDefault var isOnboarded: Bool
    ///     @ObservableUserDefault var launchCount: Int
    ///
    ///     init(container: UserDefaults = .standard) {
    ///         _isOnboarded = ObservableUserDefault(DefaultsKey("onboarded", default: false, container: container))
    ///         _launchCount = ObservableUserDefault(DefaultsKey("launch-count", default: 0, container: container))
    ///         activateDefaultsBindings() // binds both properties; no per-property `_ = ...` needed
    ///     }
    /// }
    /// ```
    ///
    /// This is the discoverable replacement for the `_ = myProperty` idiom. Because a property
    /// wrapper cannot reach its enclosing instance until first access, the forwarding subscription
    /// is otherwise installed lazily on first read — so a property never read through the instance
    /// would silently not refresh SwiftUI on external writes.
    ///
    /// Idempotent and cheap: calling it more than once, or after a property has already been read,
    /// is safe (each property binds at most once).
    @MainActor
    func activateDefaultsBindings() {
        for child in Mirror(reflecting: self).children {
            (child.value as? _DefaultsActivatable)?._activate(on: self)
        }
    }
}
