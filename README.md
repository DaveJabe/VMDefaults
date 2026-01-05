# VMDefaults

A SwiftUI-friendly, Swift 6–safe way to bind `UserDefaults` to `ObservableObject` view models.

VMDefaults provides lightweight property wrappers that:

- Persist values to `UserDefaults`
- Reactively update SwiftUI views via `ObservableObject`
- Stay in sync across multiple view models
- Correctly handle external `UserDefaults` writes
- Compile cleanly under Swift 6's strict concurrency rules

## Table of contents

- [Why this exists](#why-this-exists)
- [What this package is (and isn't)](#what-this-package-is-and-isnt)
- [When not to use this](#when-not-to-use-this)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Core types](#core-types)
    - [`DefaultsKey<Value>`](#defaultskeyvalue)
    - [`CodableDefaultsKey<Value>`](#codabledefaultskeyvalue)
    - [Property-list safety via `PropertyListValue`](#property-list-safety-via-propertylistvalue)
      - [Supported types](#supported-types)
    - [`@ObservableUserDefault`](#observableuserdefault)
      - [Publishing semantics](#publishing-semantics)
    - [Codable support via @ObservableUserDefault](#codable-support-via-observableuserdefault)
    - [Error handling (optional)](#error-handling-optional)
    - [Migrating from @AppStorage](#migrating-from-appstorage)
- [Reactive APIs](#reactive-apis)
- [Known limitations](#known-limitations)
- [Concurrency model](#concurrency-model)
- [Testing](#testing)

---

## Why this exists

### Why not `@AppStorage`?

- `@AppStorage` is view-scoped and unsuitable for MVVM

### Why not `@Observable`?

- The Observation macro has a different invalidation model and does not require manual bridging

### Why the complexity?

- SwiftUI requires `objectWillChange` to fire at exactly the right times
- `UserDefaults` does not provide a reactive API
- Bridging the two correctly and safely under Swift 6 requires care

### So there’s a gap when you want

- `ObservableObject` (still extremely common)
- View-model–owned state
- Persistence via `UserDefaults`
- Reactive updates when another screen / view model / system write mutates the same key

### VMDefaults fills that gap without

- Global mutable state
- `NotificationCenter` logic in your view models
- Manual `objectWillChange.send()`
- Race conditions under Swift 6

---

## What this package is (and isn't)

### This package is

- A `UserDefaults` → `ObservableObject` bridge
- Designed for SwiftUI + MVVM
- Safe under Swift 6 strict concurrency
- Deterministic and testable

### This package is not

- A replacement for `@AppStorage`
- A database or persistence layer
- A reactive framework
- Compatible with the `@Observable` macro (by design)

If your app is fully using `@Observable`, you do not need this package.

---

## When not to use this

You should not use VMDefaults if any of the following apply:

- Your state lives directly in views — use `@AppStorage`
- You are fully on `@Observable` — the Observation macro already handles invalidation automatically. This package exists specifically for `ObservableObject`
- You need high-volume or transactional persistence — `UserDefaults` is not suitable for large datasets, frequent writes, or atomic multi-key updates. Use SQLite, GRDB, Core Data, etc.
- You want background-thread mutation of view-model state — all mutation in this package intentionally happens on the main actor to preserve SwiftUI correctness

---

## Requirements

- Swift 6
- iOS 16 or later
- SwiftUI and `ObservableObject`
- `UserDefaults`

---

## Installation

Using Swift Package Manager:

- In Xcode, choose File > Add Packages...
- Enter this repository’s URL
- Select the latest version and add the package to your target(s)

Or in `Package.swift`:

```swift
dependencies: [
    // Replace the URL below with this repository's URL
    .package(url: "https://github.com/your-org/VMDefaults.git", from: "1.0.0")
]
```

## Usage

### Core types

#### `DefaultsKey<Value>`

Define strongly-typed keys that couple a name, default value, and container:

```swift
// Raw key with default and optional custom container
let countKey = DefaultsKey<Int>("settings.count", default: 0)

let suite = UserDefaults(suiteName: "com.example.app.tests")!
let nameKey = DefaultsKey<String?>("settings.name", default: nil, container: suite)
```

### `CodableDefaultsKey<Value>`
Define keys for Codable values. The stored representation is JSON-encoded Data:

```swift
struct Settings: Codable, Equatable, Sendable {
    var count: Int
    var name: String
}

let settingsKey = CodableDefaultsKey<Settings>(
    "settings",
    default: .init(count: 0, name: "zero")
)
```

### Property-list safety via `PropertyListValue`

#### Supported types

The `PropertyListValue` marker protocol is used to constrain raw (non-Codable) keys to types that `UserDefaults` can store directly. VMDefaults includes conformances for:

- String, Int, Double, Bool
- Data, Date
- Array<Element> where Element: PropertyListValue
- Dictionary<String, Value> where Value: PropertyListValue
- Optional<Wrapped> where Wrapped: PropertyListValue


### `@ObservableUserDefault`

Bridge a key into an ObservableObject view model. The wrapper persists updates to UserDefaults and triggers objectWillChange for SwiftUI:

```swift
@MainActor
final class CounterVM: ObservableObject {
    @ObservableUserDefault var count: Int

    init(container: UserDefaults = .standard) {
        let key = DefaultsKey<Int>("counter", default: 0, container: container)
        _count = ObservableUserDefault(key)
        _ = count // install binding eagerly (ensures immediate forwarding)
    }

    func increment() { count += 1 }
}
```
#### Publishing semantics

- Local writes publish only when the value actually changes.
   - If you set the same value again, objectWillChange is not sent (avoids spurious SwiftUI updates).
- Optional semantics: setting an optional to nil removes the key from UserDefaults (raw and Codable Optional).
- External writes:
   - Updates are coalesced per runloop turn to avoid flooding.
   - If an external write results in the same value currently held, no publication occurs.
   - Raw type mismatch or invalid Codable data falls back to the key’s default. A publication occurs only if the value actually changes.
- Container scoping and identity:
   - Observers listen only to the specific UserDefaults instance provided to the key.
   - Cross-instance writes (same suite, different UserDefaults object) are ignored by design. Inject and share the same UserDefaults instance across components that need to stay in sync.

### Codable support via `@ObservableUserDefault`

Use @ObservableUserDefault with a CodableDefaultsKey to persist Codable values:

```swift
@MainActor
final class ProfileVM: ObservableObject {
    struct Profile: Codable, Equatable, Sendable { var name: String; var age: Int }
    @ObservableUserDefault var profile: Profile

    init(container: UserDefaults = .standard) {
        let key = CodableDefaultsKey<Profile>(
            "profile",
            default: .init(name: "Anonymous", age: 0),
            container: container
        )
        _profile = ObservableUserDefault(key)
        _ = profile // install binding eagerly
    }
}
```
You can customize the JSONEncoder/JSONDecoder and provide an onError handler when initializing the wrapper if you want detailed error reporting.

### Error handling (optional)

```swift
import VMDefaults

@MainActor
VMDefaultsCoding.defaultOnError = { error in
    // Log, assert, or surface diagnostics
    print("[VMDefaults] Coding error:", error)
}
```
The onError closure can also be provided per-call on publisher/updates APIs.

### Migrating from `@AppStorage`

- @AppStorage is view-scoped; VMDefaults targets view-model–owned state with ObservableObject.
- Replace direct @AppStorage usage with strongly-typed DefaultsKey / CodableDefaultsKey.
- Initialize @ObservableUserDefault in your view model’s init, and use the property like any other stored property.
- Inject a specific UserDefaults container (suite) for tests and isolation.

## Reactive APIs

VMDefaults exposes Combine publishers and async sequences for both raw and Codable keys. Use the “distinct” variants to avoid duplicate consecutive values.

### Raw keys (Combine)

```swift
import Combine

let suite = UserDefaults(suiteName: "com.example.app.react")!
let key = DefaultsKey<Int>("react.count", default: 0, container: suite)

var cancellables = Set<AnyCancellable>()

// Emits 0 immediately, then future distinct changes.
key.distinctPublisher()
    .sink { value in
        print("[Combine] distinct raw:", value)
    }
    .store(in: &cancellables)

// Also available without duplicate filtering:
// key.publisher().sink { print("[Combine] raw:", $0) }.store(in: &cancellables)
```

### Raw keys (AsyncSequence)

```swift
let suite = UserDefaults(suiteName: "com.example.app.react")!
let key = DefaultsKey<String?>("react.name", default: nil, container: suite)

Task { @MainActor in
    var iterator = key.distinctUpdates().makeAsyncIterator()
    // Yields initial (nil), then future distinct changes.
    while let next = await iterator.next() {
        print("[Async] distinct raw:", String(describing: next))
    }
}

// Also available without duplicate filtering:
// for await v in key.updates() { print("[Async] raw:", v) }
```

### Codable keys (Combine)

```swift
import Combine

struct Settings: Codable, Equatable, Sendable {
    var count: Int
    var name: String
}

let suite = UserDefaults(suiteName: "com.example.app.react")!
let key = CodableDefaultsKey<Settings>(
    "react.settings",
    default: .init(count: 0, name: "zero"),
    container: suite
)

var cancellables = Set<AnyCancellable>()

// Emits default immediately, then future distinct decoded values.
key.distinctPublisher()
    .sink { settings in
        print("[Combine] distinct codable:", settings)
    }
    .store(in: &cancellables)

// You can customize decoder and error handling:
// key.distinctPublisher(decoder: JSONDecoder()) { error in /* log */ }
```

### Codable keys (AsyncSequence)

```swift
struct Settings: Codable, Equatable, Sendable {
    var count: Int
    var name: String
}

let suite = UserDefaults(suiteName: "com.example.app.react")!
let key = CodableDefaultsKey<Settings>(
    "react.settings",
    default: .init(count: 0, name: "zero"),
    container: suite
)

Task { @MainActor in
    var iterator = key.distinctUpdates().makeAsyncIterator()
    // Yields default first, then future distinct decoded values.
    while let next = await iterator.next() {
        print("[Async] distinct codable:", next)
    }
}

// You can customize decoder and error handling:
// for await v in key.distinctUpdates(decoder: JSONDecoder(), onError: { print($0) }) { ... }
```
### Semantics and notes

- Initial emission is always the current value (or the key’s default if missing/invalid).
- External change bursts are coalesced per runloop turn (you may see only the last value of a burst).
- “Distinct” variants remove duplicate consecutive values.
- Container scoping: streams observe only the provided UserDefaults instance (not .standard unless you explicitly use it).
- Cross-instance writes (same suite, different UserDefaults object) are ignored by design — share the same UserDefaults instance where synchronization is required.

## Known limitations

- Cross-instance writes (same suite, different `UserDefaults` object) are ignored
  - VMDefaults filters notifications by the exact `UserDefaults` instance provided to the key.
  - If you create two different `UserDefaults(suiteName:)` instances for the same suite, changes posted by one instance won’t be observed by keys bound to the other instance.
  - Recommendation: inject and share a single `UserDefaults` instance wherever you need synchronization.

- Coalescing and “latest value” semantics
  - Observable wrappers and async sequences coalesce external changes per runloop turn; you may only receive the last value of a burst.
  - “Distinct” variants remove duplicate consecutive values by design.
  - Treat streams as “latest value” feeds, not an event log.

- Container scoping
  - Streams and wrappers observe only the provided container (not `.standard` unless you explicitly use it).
  - This is intentional to prevent accidental cross-container coupling.

- Not transactional or multi-key atomic
  - `UserDefaults` is not a transactional store; multi-key updates are not atomic.
  - If you need transactional semantics, use a database or Core Data.

- Codable invalid/mismatched data falls back to default
  - When decoding fails (or a raw type mismatch occurs), VMDefaults yields the key’s default.
  - A publication occurs only if the effective value changes.
  - Consider providing an `onError` handler or a global `VMDefaultsCoding.defaultOnError` to log/diagnose failures.

- Optional semantics
  - Setting an optional raw or Codable value to `nil` removes the key.
  - Reads of a missing key return the key’s default (often `nil` for optional keys).

- Performance and payload size
  - `UserDefaults` is optimized for small values and infrequent writes.
  - Avoid storing large payloads (e.g., large JSON blobs or images). Prefer files/DB for large data.

- Main-actor mutation model
  - VMDefaults’ observable wrappers mutate view-model state on the main actor to preserve SwiftUI correctness.
  - External writes from background threads are fine, but UI-bound state changes are delivered on the main actor.

- Supported raw types
  - Raw (non-Codable) keys are limited to `PropertyListValue` types supported by this package: `String`, `Int`, `Double`, `Bool`, `Data`, `Date`, arrays/dictionaries of those, and optionals thereof.
  - If you need other types (e.g., `URL`), encode as `String`/`Data` or use a Codable key.

## Concurrency model

VMDefaults is designed to compile cleanly and behave deterministically under Swift 6’s strict concurrency checking.

- Main-actor mutation for UI-bound state
   - @ObservableUserDefault is intended to be used from @MainActor view models.
   - Property writes and publications happen on the main actor to preserve SwiftUI correctness.
   - Example:

```swift
@MainActor
    final class SettingsVM: ObservableObject {
        @ObservableUserDefault var isOnboardingComplete: Bool

        init(container: UserDefaults = .standard) {
            _isOnboardingComplete = ObservableUserDefault(
                DefaultsKey("onboarding.complete", default: false, container: container)
            )
            _ = isOnboardingComplete // eagerly install binding
        }
    }
```

- Background writes are supported; UI updates are delivered on the main actor
   - External mutations (e.g., from background tasks or other processes) are observed and coalesced.
   - Publications into SwiftUI are marshaled to the main actor.
   - You can safely write to the same UserDefaults container off the main thread:

```swift
let suite = UserDefaults(suiteName: "com.example.app.shared")!
    DispatchQueue.global().async {
        suite.set(true, forKey: "onboarding.complete")
    }
```

- Strict Sendable boundaries
   - Key types (e.g., DefaultsKey, CodableDefaultsKey) and stored values are Sendable when their Value is Sendable.
   - Codable encoding/decoding is performed on the calling context; wrapper-driven publications are main-actor confined.

- Reactive APIs honor actor isolation
   - UI-facing emissions are delivered on the main actor when sourced from the observable wrapper.
   - Async sequences (updates() / distinctUpdates()) are safe to iterate from @MainActor contexts. If you iterate off-main, hop to the main actor before mutating UI-bound state.

```swift
let key = DefaultsKey<Int>("react.count", default: 0, container: .standard)

    Task.detached {
        for await value in key.distinctUpdates() {
            await MainActor.run {
                // Safely update UI-bound state here
                // e.g., viewModel.someDerivedValue = value
            }
        }
    }
```

- Avoid cross-instance synchronization
   - Synchronization relies on observing notifications from the exact UserDefaults instance provided to the key.
   - If you need multiple components to stay in sync, inject and share the same UserDefaults instance (suite) across those components.
   

