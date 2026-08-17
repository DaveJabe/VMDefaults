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
/// - is **cross-process**: writes from an app extension/widget sharing an app-group suite are
///   observed (daemon-mediated and *eventually* consistent — see Delivery semantics)
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
/// - For **same-process** writes the handler is invoked synchronously on whatever thread
///   performed the write; callers are responsible for hopping to the main actor if needed.
/// - For **cross-process** writes (app-group suites) delivery is mediated by the preferences
///   daemon: it is asynchronous, arrives on a run-loop context, and is eventually consistent
///   (most reliable in the foreground; not guaranteed while suspended).
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

    /// Whether `key` can be observed via KVO on a `UserDefaults` suite.
    ///
    /// KVO interprets a key containing "." as a nested key path (which never fires for a flat
    /// `set(_:forKey:)`) and a leading "@" as a collection operator, so such keys are not
    /// KVC-observable. Plain `get()`/`set()` still work with any key name — only observation
    /// (`@ObservableUserDefault`, `publisher()`, `updates()`) is affected.
    static func isKVCObservable(_ key: String) -> Bool {
        !key.contains(".") && !key.hasPrefix("@")
    }

    #if DEBUG
    /// Test-only seam: invoked synchronously with `(defaults, key)` immediately **before** the KVO
    /// observer is registered. Lets tests deterministically interleave a write into the
    /// "snapshot → addObserver" installation window (the race a launch-time widget write can hit)
    /// instead of relying on a wall-clock stress interleave. Lock-guarded because observations are
    /// created from arbitrary isolation domains (main-actor boxes/streams, publisher subscriptions).
    private static let _beforeInstallHookLock = NSLock()
    nonisolated(unsafe) private static var _beforeInstallHook: (@Sendable (UserDefaults, String) -> Void)?
    static func _setBeforeInstallHook(_ hook: (@Sendable (UserDefaults, String) -> Void)?) {
        _beforeInstallHookLock.lock()
        defer { _beforeInstallHookLock.unlock() }
        _beforeInstallHook = hook
    }
    private static func _invokeBeforeInstallHook(defaults: UserDefaults, key: String) {
        _beforeInstallHookLock.lock()
        let hook = _beforeInstallHook
        _beforeInstallHookLock.unlock()
        hook?(defaults, key)
    }
    #endif

    init(defaults: UserDefaults, key: String, handler: @escaping @Sendable () -> Void) {
        assert(
            Self.isKVCObservable(key),
            "VMDefaults: UserDefaults key \"\(key)\" is not KVC-compliant (contains '.' or starts with '@'). KVO-based observation will never fire for this key. Rename the key to remove '.'/'@'."
        )
        self.defaults = defaults
        self.key = key
        self.handler = handler
        super.init()
        #if DEBUG
        Self._invokeBeforeInstallHook(defaults: defaults, key: key)
        #endif
        defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    // Note: the string-keyPath KVO API is required here (not block-based `observe(_:)`), because
    // UserDefaults keys are dynamic strings and `NSObject.observe(_:)` needs a compile-time KeyPath.
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
        let subscription = KeyChangeSubscription(defaults: defaults, key: key, subscriber: AnySubscriber(subscriber))
        subscriber.receive(subscription: subscription)
    }

    // The subscriber is type-erased to `AnySubscriber` so this class is *non-generic*. A generic
    // `KeyChangeSubscription<S>` made the `@Sendable` KVO handler implicitly capture the
    // non-Sendable metatype `S.Type`, which Swift 6 flags with a `#SendableMetatypes` warning.
    // Erasure removes the generic parameter (and thus the captured metatype) without weakening
    // any invariant: the demand bookkeeping and observation lifetime are unchanged.
    private final class KeyChangeSubscription: Subscription, @unchecked Sendable {
        // @unchecked Sendable justification: all mutable state (`subscriber`, `demand`,
        // `observation`) is accessed only under `lock`. The downstream `subscriber` is
        // invoked outside the lock, on the writing thread — the same contract as
        // NotificationCenter.Publisher, which this type replaces.
        private let lock = NSLock()
        private var subscriber: AnySubscriber<Void, Never>?
        private var demand = Subscribers.Demand.none
        private var observation: UserDefaultsKeyObservation?

        init(defaults: UserDefaults, key: String, subscriber: AnySubscriber<Void, Never>) {
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
