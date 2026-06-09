//
//  DefaultsAccessors.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//

import Foundation
import Combine

public extension DefaultsKey where Value: PropertyListValue {
    /// Returns the current value for this key from its container, or the key’s default if missing.
    ///
    /// This is a simple, non-observable accessor. It does not install any bindings or publish changes.
    @MainActor
    func get() -> Value {
        _readRaw(from: container, key: name, defaultValue: defaultValue)
    }

    @MainActor
    func set(_ value: Value) {
        _writeRaw(to: container, key: name, newValue: value)
    }
}

public extension DefaultsKey where Value: PropertyListValue & Sendable {
    /// A Combine publisher that emits the current value and subsequent updates for this key.
    /// This is a read-only, non-observable-object stream.
    @MainActor
    func publisher() -> AnyPublisher<Value, Never> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return Deferred {
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification, object: containerRef)
                .receive(on: DispatchQueue.main)
                .map { _ in _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal) }
                .prepend(_readRaw(from: containerRef, key: keyName, defaultValue: defaultVal))
        }
        .eraseToAnyPublisher()
    }

    /// An AsyncSequence that yields the current value and subsequent updates for this key.
    /// Bursts of notifications are coalesced to a single yield per runloop turn.
    @MainActor
    func updates() -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        let notifications = NotificationCenter.default.notifications(
            named: UserDefaults.didChangeNotification,
            object: containerRef
        )
        return AsyncStream { continuation in
            let initial = _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
            continuation.yield(initial)

            let task = Task { @MainActor in
                var isScheduled = false
                for await _ in notifications {
                    if isScheduled { continue }
                    isScheduled = true
                    await Task.yield() // collapse bursts into one refresh
                    isScheduled = false
                    let latest = _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
                    continuation.yield(latest)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension DefaultsKey where Value: PropertyListValue & Equatable & Sendable {
    /// A Combine publisher that removes duplicate consecutive values.
    @MainActor
    func distinctPublisher() -> AnyPublisher<Value, Never> {
        publisher().removeDuplicates().eraseToAnyPublisher()
    }

    /// An AsyncSequence that yields only when the value actually changes.
    @MainActor
    func distinctUpdates() -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        let notifications = NotificationCenter.default.notifications(
            named: UserDefaults.didChangeNotification,
            object: containerRef
        )
        return AsyncStream { continuation in
            let initial = _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
            continuation.yield(initial)

            let task = Task { @MainActor in
                var isScheduled = false
                var last = initial
                for await _ in notifications {
                    if isScheduled { continue }
                    isScheduled = true
                    await Task.yield()
                    isScheduled = false
                    let latest = _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
                    if !(latest == last) {
                        last = latest
                        continuation.yield(latest)
                    }
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension CodableDefaultsKey where Value: Sendable {
    /// Returns the current Codable value for this key by decoding JSON `Data` from its container,
    /// or the key’s default if missing or if decoding fails.
    @MainActor
    func get(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> Value {
        guard let data = container.data(forKey: name) else {
            return defaultValue
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
            return defaultValue
        }
    }

    /// Encodes and stores a Codable value for this key using JSON.
    /// If the value is an Optional.none, removes the key from the container.
    @MainActor
    func set(
        _ value: Value,
        encoder: JSONEncoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        if let opt = value as? _AnyOptional, opt._isNil {
            container.removeObject(forKey: name)
            return
        }
        do {
            let data = try encoder.encode(value)
            container.set(data, forKey: name)
        } catch {
            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
        }
    }

    /// A Combine publisher that decodes JSON Data for this key and emits the current and future values.
    @MainActor
    func publisher(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AnyPublisher<Value, Never> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        let decode: () -> Value = {
            if let data = containerRef.data(forKey: keyName) {
                do { return try decoder.decode(Value.self, from: data) }
                catch { (onError ?? VMDefaultsCoding.defaultOnError)?(error); return defaultVal }
            } else {
                return defaultVal
            }
        }
        return Deferred {
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification, object: containerRef)
                .receive(on: DispatchQueue.main)
                .map { _ in decode() }
                .prepend(decode())
        }
        .eraseToAnyPublisher()
    }

    /// An AsyncSequence that decodes JSON Data for this key and yields the current and future values.
    @MainActor
    func updates(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        let notifications = NotificationCenter.default.notifications(
            named: UserDefaults.didChangeNotification,
            object: containerRef
        )
        return AsyncStream { continuation in
            // Initial
            let initial: Value
            if let data = containerRef.data(forKey: keyName) {
                initial = (try? decoder.decode(Value.self, from: data)) ?? defaultVal
            } else {
                initial = defaultVal
            }
            continuation.yield(initial)

            let task = Task { @MainActor in
                var isScheduled = false
                for await _ in notifications {
                    if isScheduled { continue }
                    isScheduled = true
                    await Task.yield()
                    isScheduled = false
                    if let data = containerRef.data(forKey: keyName) {
                        do {
                            let value = try decoder.decode(Value.self, from: data)
                            continuation.yield(value)
                        } catch {
                            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
                            continuation.yield(defaultVal)
                        }
                    } else {
                        continuation.yield(defaultVal)
                    }
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension CodableDefaultsKey where Value: Equatable & Sendable {
    /// A Combine publisher for Codable values that removes duplicate consecutive emissions.
    @MainActor
    func distinctPublisher(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AnyPublisher<Value, Never> {
        publisher(decoder: decoder, onError: onError).removeDuplicates().eraseToAnyPublisher()
    }

    /// An AsyncSequence for Codable values that yields only when the decoded value actually changes.
    @MainActor
    func distinctUpdates(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        let notifications = NotificationCenter.default.notifications(
            named: UserDefaults.didChangeNotification,
            object: containerRef
        )
        return AsyncStream { continuation in
            let initial: Value
            if let data = containerRef.data(forKey: keyName) {
                initial = (try? decoder.decode(Value.self, from: data)) ?? defaultVal
            } else {
                initial = defaultVal
            }
            continuation.yield(initial)

            let task = Task { @MainActor in
                var isScheduled = false
                var last = initial
                for await _ in notifications {
                    if isScheduled { continue }
                    isScheduled = true
                    await Task.yield()
                    isScheduled = false
                    if let data = containerRef.data(forKey: keyName) {
                        do {
                            let value = try decoder.decode(Value.self, from: data)
                            if !(value == last) {
                                last = value
                                continuation.yield(value)
                            }
                        } catch {
                            (onError ?? VMDefaultsCoding.defaultOnError)?(error)
                            if !(defaultVal == last) {
                                last = defaultVal
                                continuation.yield(defaultVal)
                            }
                        }
                    } else if !(defaultVal == last) {
                        last = defaultVal
                        continuation.yield(defaultVal)
                    }
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

