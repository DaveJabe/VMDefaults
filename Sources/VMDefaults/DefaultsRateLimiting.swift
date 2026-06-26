//
//  DefaultsRateLimiting.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//

import Foundation

/// Wraps an `AsyncStream` so that a value is only yielded after `interval` has elapsed with no
/// newer value (debounce). Each incoming value cancels the previously-scheduled emission. The
/// initial value is also subject to the delay.
///
/// AsyncStream consumers have no built-in `debounce` (unlike Combine, where you can chain
/// `.debounce` on `publisher()`); this gives the async variants parity.
@MainActor
func _debounced<Value: Sendable>(_ upstream: AsyncStream<Value>, for interval: Duration) -> AsyncStream<Value> {
    AsyncStream { continuation in
        let task = Task { @MainActor in
            var pending: Task<Void, Never>?
            for await value in upstream {
                pending?.cancel()
                pending = Task { @MainActor in
                    // Task.sleep throws on cancellation (a newer value arrived) — swallow and drop.
                    guard (try? await Task.sleep(for: interval)) != nil else { return }
                    continuation.yield(value)
                }
            }
            pending?.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

public extension DefaultsKey where Value: PropertyListValue & Sendable {
    /// An `AsyncStream` that yields a value only after `interval` has elapsed with no further
    /// change (debounce). Useful to rate-limit expensive reactions to a rapidly-changing key.
    @MainActor
    func debouncedUpdates(for interval: Duration) -> AsyncStream<Value> {
        _debounced(updates(), for: interval)
    }
}

public extension CodableDefaultsKey where Value: Sendable {
    /// An `AsyncStream` that yields a decoded value only after `interval` has elapsed with no
    /// further change (debounce).
    @MainActor
    func debouncedUpdates(
        for interval: Duration,
        decoder: JSONDecoder = .init(),
        onError: (@Sendable (Error) -> Void)? = nil
    ) -> AsyncStream<Value> {
        _debounced(updates(decoder: decoder, onError: onError), for: interval)
    }
}
