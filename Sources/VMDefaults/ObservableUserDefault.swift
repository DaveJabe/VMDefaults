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
/// is accessed through its enclosing instance's subscript. For `private` properties that are
/// never read externally, call `_ = myProperty` inside the enclosing type's `init` to eagerly
/// install the subscription so that external UserDefaults writes trigger re-renders immediately.
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

        func report(_ error: Error) {
            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
        }

        func read() -> Value {
            guard let data = key.container.data(forKey: key.name) else { return key.defaultValue }
            do { return try decoder.decode(Value.self, from: data) }
            catch { report(error); return key.defaultValue }
        }

        func write(_ newValue: Value) {
            if let opt = newValue as? _AnyOptional, opt._isNil {
                key.container.removeObject(forKey: key.name)
                return
            }
            do {
                let data = try encoder.encode(newValue)
                key.container.set(data, forKey: key.name)
            } catch {
                report(error)
            }
        }

        self.box = DefaultsBox(
            container: key.container,
            key: key.name,
            initialValue: read(),
            read: read,
            write: write
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

        func report(_ error: Error) {
            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
        }

        func read() -> Value {
            guard let data = container.data(forKey: key) else { return defaultValue }
            do { return try decoder.decode(Value.self, from: data) }
            catch { report(error); return defaultValue }
        }

        func write(_ newValue: Value) {
            if let opt = newValue as? _AnyOptional, opt._isNil {
                container.removeObject(forKey: key)
                return
            }
            do {
                let data = try encoder.encode(newValue)
                container.set(data, forKey: key)
            } catch {
                report(error)
            }
        }

        self.box = DefaultsBox(
            container: container,
            key: key,
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
        let token = _token(on: instance as AnyObject, id: tokenID)
        guard token.cancellable == nil else { return }

        token.cancellable = box.$value
            .dropFirst()
            .sink { [weak instance] _ in
                guard let instance else { return }
                if token.isInternalWrite {
                    token.isInternalWrite = false
                    return
                }
                instance.objectWillChange.send()
            }
    }
}

