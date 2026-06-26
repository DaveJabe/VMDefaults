//
//  ObservableUserDefault.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine

/// A property wrapper that keeps an `ObservableObject` property in sync with a UserDefaults value.
///
/// **Lazy binding**: the `objectWillChange` subscription is installed the first time the property
/// is accessed through its enclosing instance's subscript. A property that is never read through
/// the instance (e.g. a `private` flag observed only indirectly) would therefore not refresh
/// SwiftUI on external UserDefaults writes. To install forwarding eagerly, call
/// ``activateDefaultsBindings()`` once at the end of your `ObservableObject`'s `init` — it binds
/// every `@ObservableUserDefault` property on the instance. (Reading `_ = myProperty` in `init`
/// also works for a single property, but `activateDefaultsBindings()` is preferred: it is
/// discoverable, covers all properties at once, and is not silently stripped by linters.)
@MainActor
@propertyWrapper
public struct ObservableUserDefault<Value: Equatable & Sendable> {
    private let box: DefaultsBox<Value>
    private let tokenID = UUID().uuidString
    private let onError: (@Sendable (Error) -> Void)?

    public init(_ key: DefaultsKey<Value>) where Value: PropertyListValue {
        let initial = _readRaw(from: key.container, key: key.name, defaultValue: key.defaultValue)
        self.onError = nil

        self.box = DefaultsBox(
            container: key.container,
            key: key.name,
            initialValue: initial,
            read: { _readRaw(from: key.container, key: key.name, defaultValue: key.defaultValue) },
            write: { _writeRaw(to: key.container, key: key.name, newValue: $0) }
        )
    }

    public init(key: String, defaultValue: Value, container: UserDefaults = .standard) where Value: PropertyListValue {
        let initial = _readRaw(from: container, key: key, defaultValue: defaultValue)
        self.onError = nil

        self.box = DefaultsBox(
            container: container,
            key: key,
            initialValue: initial,
            read: { _readRaw(from: container, key: key, defaultValue: defaultValue) },
            write: { _writeRaw(to: container, key: key, newValue: $0) }
        )
    }

    public init(
        _ key: CodableDefaultsKey<Value>,
        encoder: JSONEncoder = .init(),
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) where Value: Codable {
        self.onError = onError
        let container = key.container
        let name = key.name
        let defaultValue = key.defaultValue

        self.box = DefaultsBox(
            container: container,
            key: name,
            initialValue: _readCodable(from: container, key: name, defaultValue: defaultValue, decoder: decoder, onError: onError),
            read: { _readCodable(from: container, key: name, defaultValue: defaultValue, decoder: decoder, onError: onError) },
            write: { _writeCodable(to: container, key: name, newValue: $0, encoder: encoder, onError: onError) }
        )
    }

    public init(
        codableKey key: String,
        defaultValue: Value,
        container: UserDefaults = .standard,
        encoder: JSONEncoder = .init(),
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) where Value: Codable {
        self.onError = onError

        self.box = DefaultsBox(
            container: container,
            key: key,
            initialValue: _readCodable(from: container, key: key, defaultValue: defaultValue, decoder: decoder, onError: onError),
            read: { _readCodable(from: container, key: key, defaultValue: defaultValue, decoder: decoder, onError: onError) },
            write: { _writeCodable(to: container, key: key, newValue: $0, encoder: encoder, onError: onError) }
        )
    }

    /// Bridges a ``TransformedDefaultsKey`` (e.g. a `RawRepresentable` enum, `URL`, or `UUID` stored
    /// as a native property-list scalar) into an `ObservableObject` view model.
    public init<Stored: PropertyListValue & Sendable>(_ key: TransformedDefaultsKey<Value, Stored>) {
        self.onError = nil
        let container = key.container
        let name = key.name
        let defaultValue = key.defaultValue
        let encode = key.encode
        let decode = key.decode

        let read: @MainActor () -> Value = {
            guard container.object(forKey: name) != nil else { return defaultValue }
            return decode(_readRaw(from: container, key: name, defaultValue: encode(defaultValue))) ?? defaultValue
        }
        let write: @MainActor (Value) -> Void = {
            _writeRaw(to: container, key: name, newValue: encode($0))
        }

        self.box = DefaultsBox(
            container: container,
            key: name,
            initialValue: read(),
            read: read,
            write: write
        )
    }

    /// `@ObservableUserDefault` only works through the enclosing-instance static subscript,
    /// which requires the property to live on an `ObservableObject` class. Marking these
    /// accessors unavailable (the same technique `@Published` uses) turns misuse — e.g. on a
    /// struct, a local variable, or a non-ObservableObject class — into a compile-time error
    /// instead of a runtime `fatalError`.
    @available(*, unavailable, message: "@ObservableUserDefault must be used on a property of an ObservableObject class")
    public var wrappedValue: Value {
        get { fatalError("Unreachable: wrappedValue is unavailable; access goes through the enclosing-instance subscript.") }
        set { fatalError("Unreachable: wrappedValue is unavailable; access goes through the enclosing-instance subscript.") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, ObservableUserDefault>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.ensureBound(to: instance)
            return wrapper.box.value
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.ensureBound(to: instance)

            guard !(newValue == wrapper.box.value) else { return }

            let token = _token(on: instance as AnyObject, id: wrapper.tokenID)
            token.isInternalWrite = true
            instance.objectWillChange.send()
            wrapper.box.set(newValue)
        }
    }

    private func ensureBound<EnclosingSelf: ObservableObject>(to instance: EnclosingSelf)
    where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        #if DEBUG
        // Record that forwarding is (about to be) installed, so the box does not emit the
        // "unbound external write" debug warning for this property.
        box.hasForwardingBinding = true
        #endif
        let token = _token(on: instance as AnyObject, id: tokenID)
        guard token.cancellable == nil else { return }

        // Capture both `instance` and `token` weakly. `token` is kept alive for the duration of
        // the binding by `storage.tokensByID` (an associated object on `instance`); capturing it
        // weakly here is what prevents a retain cycle. With a strong capture, the graph
        // token -> cancellable -> Combine sink -> closure -> token forms a self-sustaining cycle
        // that outlives `instance` and leaks one token + cancellable + sink per bound property,
        // per destroyed view model. When `instance` deallocates, `storage` releases `token`,
        // `token`'s `cancellable` deinitializes, and the subscription tears down.
        token.cancellable = box.$value
            .dropFirst()
            .sink { [weak instance, weak token] _ in
                guard let instance, let token else { return }
                if token.isInternalWrite {
                    token.isInternalWrite = false
                    return
                }
                instance.objectWillChange.send()
            }
    }
}

// MARK: - Eager activation

extension ObservableUserDefault: _DefaultsActivatable {
    /// Installs change-forwarding for this wrapper on `instance`. Invoked by
    /// ``activateDefaultsBindings()`` via reflection so the `Value` type can stay erased.
    func _activate<O: ObservableObject>(on instance: O)
    where O.ObjectWillChangePublisher == ObservableObjectPublisher {
        ensureBound(to: instance)
    }
}

