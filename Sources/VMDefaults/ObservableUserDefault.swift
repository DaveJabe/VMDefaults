//
//  ObservableUserDefault.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine

@MainActor
@propertyWrapper
public struct ObservableUserDefault<Value: Equatable & Sendable> {
    private let box: DefaultsBox<Value>
    private let tokenID = UUID().uuidString

    public init(_ key: DefaultsKey<Value>) {
        let initial = _readRaw(from: key.container, key: key.name, defaultValue: key.defaultValue)

        self.box = DefaultsBox(
            container: key.container,
            initialValue: initial,
            read: { _readRaw(from: key.container, key: key.name, defaultValue: key.defaultValue) },
            write: { _writeRaw(to: key.container, key: key.name, newValue: $0) }
        )
    }

    public init(key: String, defaultValue: Value, container: UserDefaults = .standard) {
        let initial = _readRaw(from: container, key: key, defaultValue: defaultValue)

        self.box = DefaultsBox(
            container: container,
            initialValue: initial,
            read: { _readRaw(from: container, key: key, defaultValue: defaultValue) },
            write: { _writeRaw(to: container, key: key, newValue: $0) }
        )
    }

    public var wrappedValue: Value {
        get { fatalError("ObservableUserDefault must be used on a class (ObservableObject) property.") }
        set { fatalError("ObservableUserDefault must be used on a class (ObservableObject) property.") }
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

            guard newValue != wrapper.box.value else { return }

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
