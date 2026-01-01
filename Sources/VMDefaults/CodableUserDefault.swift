//
//  CodableUserDefault.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine

public enum VMDefaultsCoding {
    @MainActor
    public static var defaultOnError: (@Sendable (Error) -> Void)?
}

@MainActor
@propertyWrapper
public struct CodableUserDefault<Value: Codable & Equatable & Sendable> {
    private let box: DefaultsBox<Value>
    private let tokenID = UUID().uuidString
    private let onError: (@Sendable (Error) -> Void)?

    public init(
        _ key: DefaultsKey<Value>,
        encoder: JSONEncoder = .init(),
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
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
            do {
                let data = try encoder.encode(newValue)
                key.container.set(data, forKey: key.name)
            } catch {
                report(error)
            }
        }

        self.box = DefaultsBox(container: key.container, initialValue: read(), read: read, write: write)
    }

    public var wrappedValue: Value {
        get { fatalError("CodableUserDefault must be used on a class (ObservableObject) property.") }
        set { fatalError("CodableUserDefault must be used on a class (ObservableObject) property.") }
    }

    public static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, CodableUserDefault>
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
