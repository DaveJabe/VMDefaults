//
//  DefaultsAccessors.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//

import Foundation
import Combine

// MARK: - Shared coalescing engine

/// Builds an `AsyncStream` that yields the current value immediately, then re-reads and yields
/// after each KVO change to `key`.
///
/// Bursts within a single runloop turn are coalesced to one yield: the underlying `_keyChanges`
/// stream buffers only the newest change (`.bufferingNewest(1)`), and the `Task.yield()` lets a
/// burst land before the re-read. When `isDuplicate` is supplied, consecutive equal values are
/// suppressed (the "distinct" variants); when it is `nil`, every change yields.
///
/// This is the single source of truth for the raw and Codable `updates()`/`distinctUpdates()`
/// accessors — they differ only in their `read` closure and whether they pass `isDuplicate`.
@MainActor
func _coalescedStream<Value: Sendable>(
    in defaults: UserDefaults,
    key: String,
    read: @escaping @MainActor () -> Value,
    isDuplicate: (@MainActor (Value, Value) -> Bool)? = nil
) -> AsyncStream<Value> {
    let changes = _keyChanges(in: defaults, key: key)
    return AsyncStream { continuation in
        let initial = read()
        continuation.yield(initial)

        let task = Task { @MainActor in
            var last = initial
            for await _ in changes {
                await Task.yield() // collapse a burst within one runloop turn before re-reading
                let latest = read()
                if let isDuplicate, isDuplicate(latest, last) { continue }
                last = latest
                continuation.yield(latest)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Raw keys

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
    ///
    /// Observation is KVO-based: suite-scoped, cross-process, and per-key (writes to other
    /// keys do not emit). The key name must be KVC-compliant (must not contain ".").
    @MainActor
    func publisher() -> AnyPublisher<Value, Never> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return Deferred {
            UserDefaultsKeyChangePublisher(defaults: containerRef, key: keyName)
                .receive(on: DispatchQueue.main)
                .map { _ in _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal) }
                .prepend(_readRaw(from: containerRef, key: keyName, defaultValue: defaultVal))
        }
        .eraseToAnyPublisher()
    }

    /// An AsyncSequence that yields the current value and subsequent updates for this key.
    /// Bursts of changes are coalesced to a single yield per runloop turn.
    ///
    /// Observation is KVO-based: suite-scoped, cross-process, and per-key (writes to other
    /// keys do not yield). The key name must be KVC-compliant (must not contain ".").
    @MainActor
    func updates() -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return _coalescedStream(in: containerRef, key: keyName, read: {
            _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
        })
    }
}

public extension DefaultsKey where Value: PropertyListValue & Equatable & Sendable {
    /// A Combine publisher that removes duplicate consecutive values.
    @MainActor
    func distinctPublisher() -> AnyPublisher<Value, Never> {
        publisher().removeDuplicates().eraseToAnyPublisher()
    }

    /// An AsyncSequence that yields only when the value actually changes.
    ///
    /// Observation is KVO-based: suite-scoped, cross-process, and per-key (writes to other
    /// keys do not yield). The key name must be KVC-compliant (must not contain ".").
    @MainActor
    func distinctUpdates() -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return _coalescedStream(in: containerRef, key: keyName, read: {
            _readRaw(from: containerRef, key: keyName, defaultValue: defaultVal)
        }, isDuplicate: { $0 == $1 })
    }
}

// MARK: - Codable keys

public extension CodableDefaultsKey where Value: Sendable {
    /// Returns the current Codable value for this key by decoding JSON `Data` from its container,
    /// or the key’s default if missing or if decoding fails.
    @MainActor
    func get(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> Value {
        _readCodable(from: container, key: name, defaultValue: defaultValue, decoder: decoder, onError: onError)
    }

    /// Encodes and stores a Codable value for this key using JSON.
    /// If the value is an Optional.none, removes the key from the container.
    @MainActor
    func set(
        _ value: Value,
        encoder: JSONEncoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        _writeCodable(to: container, key: name, newValue: value, encoder: encoder, onError: onError)
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
        let decode: @MainActor () -> Value = {
            _readCodable(from: containerRef, key: keyName, defaultValue: defaultVal, decoder: decoder, onError: onError)
        }
        return Deferred {
            UserDefaultsKeyChangePublisher(defaults: containerRef, key: keyName)
                .receive(on: DispatchQueue.main)
                .map { _ in decode() }
                .prepend(decode())
        }
        .eraseToAnyPublisher()
    }

    /// An AsyncSequence that decodes JSON Data for this key and yields the current and future values.
    ///
    /// Observation is KVO-based: suite-scoped, cross-process, and per-key (writes to other
    /// keys do not yield). The key name must be KVC-compliant (must not contain ".").
    @MainActor
    func updates(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return _coalescedStream(in: containerRef, key: keyName, read: {
            _readCodable(from: containerRef, key: keyName, defaultValue: defaultVal, decoder: decoder, onError: onError)
        })
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
    ///
    /// Observation is KVO-based: suite-scoped, cross-process, and per-key (writes to other
    /// keys do not yield). The key name must be KVC-compliant (must not contain ".").
    @MainActor
    func distinctUpdates(
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<Value> {
        let containerRef = container
        let keyName = name
        let defaultVal = defaultValue
        return _coalescedStream(in: containerRef, key: keyName, read: {
            _readCodable(from: containerRef, key: keyName, defaultValue: defaultVal, decoder: decoder, onError: onError)
        }, isDuplicate: { $0 == $1 })
    }
}
