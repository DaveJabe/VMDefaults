//
//  UserDefaultsKeyObservation.swift
//  VMDefaults
//
//  Created by David Jabech on 6/9/26.
//

import Foundation
import Combine

/// KVO-based, per-key observation of a UserDefaults suite.
///
/// Unlike `UserDefaults.didChangeNotification` — which is scoped to a single `UserDefaults`
/// *instance*, fires for *any* key, and never fires for writes made by other processes —
/// key-value observing a `UserDefaults` key:
/// - is **suite-scoped**: writes through any `UserDefaults` instance of the same suite are observed
/// - is **cross-process**: writes from an app extension/widget sharing an app-group suite are observed
/// - is **per-key**: only changes to the observed key fire the handler
///
/// ## Key name limitation
/// The observed key must be a valid KVC key. In particular, **keys containing "." are
/// interpreted by KVO as nested key paths and will not be observed** (verified empirically:
/// `addObserver(forKeyPath: "a.b")` never fires for `set(_:forKey: "a.b")`). Keys must also
/// not begin with "@". A debug assertion fires for dotted keys; in release builds observation
/// silently degrades to never firing for such keys.
///
/// ## Delivery semantics
/// - The handler is invoked synchronously on whatever thread performed the write; callers
///   are responsible for hopping to the main actor if needed.
/// - UserDefaults coalesces no-op writes: setting a key to a value equal to the currently
///   stored one does **not** fire KVO.
final class UserDefaultsKeyObservation: NSObject, @unchecked Sendable {
    // @unchecked Sendable justification:
    // - `defaults`, `key`, and `handler` are immutable (`let`), `handler` is @Sendable,
    //   and `UserDefaults` is documented thread-safe.
    // - The only mutable state, `isActive`, is guarded by `lock`, making `invalidate()`
    //   idempotent and safe to call from any thread (e.g. AsyncStream onTermination
    //   racing deinit).
    private let defaults: UserDefaults
    private let key: String
    private let handler: @Sendable () -> Void
    private let lock = NSLock()
    private var isActive = true

    init(defaults: UserDefaults, key: String, handler: @escaping @Sendable () -> Void) {
        assert(
            !key.contains(".") && !key.hasPrefix("@"),
            "VMDefaults: UserDefaults key \"\(key)\" is not KVC-compliant (contains '.' or starts with '@'). KVO-based observation will never fire for this key. Rename the key to remove '.'/'@'."
        )
        self.defaults = defaults
        self.key = key
        self.handler = handler
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    // swiftlint:disable:next block_based_kvo - UserDefaults keys are dynamic strings, so the
    // string-keyPath KVO API is required (NSObject.observe(_:) needs a compile-time KeyPath).
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        handler()
    }

    /// Stops observing. Idempotent and thread-safe; also called automatically on deinit.
    func invalidate() {
        lock.lock()
        let wasActive = isActive
        isActive = false
        lock.unlock()
        guard wasActive else { return }
        defaults.removeObserver(self, forKeyPath: key)
    }

    deinit { invalidate() }
}

// MARK: - AsyncStream of per-key changes

/// A `Void` AsyncStream that emits whenever `key` changes in `defaults`' suite (KVO-based).
///
/// Bursts are coalesced at the source via `.bufferingNewest(1)`: if multiple changes land
/// before the consumer resumes, they collapse into a single pending element (the consumer
/// re-reads the latest value anyway).
func _keyChanges(in defaults: UserDefaults, key: String) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let observation = UserDefaultsKeyObservation(defaults: defaults, key: key) {
            continuation.yield(())
        }
        continuation.onTermination = { _ in observation.invalidate() }
    }
}

// MARK: - Combine publisher of per-key changes

/// A publisher that emits `Void` whenever `key` changes in `defaults`' suite (KVO-based).
///
/// Each subscription installs its own KVO observation, which is removed on cancellation
/// (or when the subscription is deallocated). Values are emitted on the thread that
/// performed the write; pair with `.receive(on: DispatchQueue.main)` for UI work.
struct UserDefaultsKeyChangePublisher: Publisher {
    typealias Output = Void
    typealias Failure = Never

    let defaults: UserDefaults
    let key: String

    func receive<S: Subscriber>(subscriber: S) where S.Input == Void, S.Failure == Never {
        let subscription = KeyChangeSubscription(defaults: defaults, key: key, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }

    private final class KeyChangeSubscription<S: Subscriber>: Subscription, @unchecked Sendable
    where S.Input == Void, S.Failure == Never {
        // @unchecked Sendable justification: all mutable state (`subscriber`, `demand`,
        // `observation`) is accessed only under `lock`. The downstream `subscriber` is
        // invoked outside the lock, on the writing thread — the same contract as
        // NotificationCenter.Publisher, which this type replaces.
        private let lock = NSLock()
        private var subscriber: S?
        private var demand = Subscribers.Demand.none
        private var observation: UserDefaultsKeyObservation?

        init(defaults: UserDefaults, key: String, subscriber: S) {
            self.subscriber = subscriber
            self.observation = UserDefaultsKeyObservation(defaults: defaults, key: key) { [weak self] in
                self?.keyDidChange()
            }
        }

        private func keyDidChange() {
            lock.lock()
            guard let downstream = subscriber, demand > .none else {
                lock.unlock()
                return
            }
            demand -= 1
            lock.unlock()

            let more = downstream.receive(())
            if more > .none {
                lock.lock()
                demand += more
                lock.unlock()
            }
        }

        func request(_ demand: Subscribers.Demand) {
            lock.lock()
            self.demand += demand
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let obs = observation
            observation = nil
            subscriber = nil
            lock.unlock()
            obs?.invalidate()
        }

        deinit { observation?.invalidate() }
    }
}
