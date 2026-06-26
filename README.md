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
- [Additional APIs](#additional-apis)
  - [Eager activation](#eager-activation)
  - [Raw storage of enums, URL, and UUID](#raw-storage-of-enums-url-and-uuid)
  - [reset() / isStored](#reset--isstored)
  - [App-group helper](#app-group-helper)
  - [Debounced async updates](#debounced-async-updates)
  - [Using `@Observable`](#using-observable-observation-framework)
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

- Swift 6.2 toolchain (the package declares `swift-tools-version: 6.2` and builds in the Swift 6 language mode)
- iOS 16+ / macOS 13+ (tvOS, watchOS, and visionOS are not declared or tested)
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
    // Replace the URL below with this repository's URL.
    .package(url: "https://github.com/your-org/VMDefaults.git", from: "0.1.0")
]
```

## Usage

### Core types

#### `DefaultsKey<Value>`

Define strongly-typed keys that couple a name, default value, and container:

```swift
// Raw key with default and optional custom container
let countKey = DefaultsKey<Int>("settings-count", default: 0)

let suite = UserDefaults(suiteName: "com.example.app.tests")!
let nameKey = DefaultsKey<String?>("settings-name", default: nil, container: suite)
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
- `Array<Element>` where `Element` is a **non-optional** property-list value
- `Dictionary<String, Value>` where `Value` is a **non-optional** property-list value
- `Optional<Wrapped>` where `Wrapped` is a **non-optional** property-list value (top-level optionals only)

> **Optional shapes are deliberately restricted.** Collection-of-optional and nested-optional keys
> — `[Int?]`, `[String: Int?]`, `Int??` — are rejected at **compile time**. Stored as a property
> list they would contain a null, which CoreFoundation rejects by `abort()`-ing the process (in
> release builds too). For optional elements use a `CodableDefaultsKey`. A top-level optional
> (`DefaultsKey<Int?>`) is fully supported: `nil` maps to `removeObject`.

For non-property-list scalars such as `RawRepresentable` enums, `URL`, and `UUID`, see
[Raw storage of enums, URL, and UUID](#raw-storage-of-enums-url-and-uuid) below.


### `@ObservableUserDefault`

Bridge a key into an ObservableObject view model. The wrapper persists updates to UserDefaults and triggers objectWillChange for SwiftUI:

```swift
@MainActor
final class CounterVM: ObservableObject {
    @ObservableUserDefault var count: Int

    init(container: UserDefaults = .standard) {
        let key = DefaultsKey<Int>("counter", default: 0, container: container)
        _count = ObservableUserDefault(key)
        activateDefaultsBindings() // install change-forwarding eagerly (see note below)
    }

    func increment() { count += 1 }
}
```

> **Activate your bindings.** A property wrapper can't reach its enclosing instance until the
> property is first read, so change-forwarding installs lazily on first access. A property that is
> never read through the instance (e.g. a `private` flag) would therefore not refresh SwiftUI on
> external writes. Call `activateDefaultsBindings()` once at the end of `init` to bind every
> `@ObservableUserDefault` property up front. (Reading `_ = count` in `init` also works for a single
> property, but `activateDefaultsBindings()` is preferred — it's discoverable, covers all
> properties, and isn't silently stripped by linters. In DEBUG builds, an external write to an
> unactivated property logs a one-time warning.)
```
#### Publishing semantics

- Local writes publish only when the value actually changes.
   - If you set the same value again, objectWillChange is not sent (avoids spurious SwiftUI updates).
- Optional semantics: setting an optional to nil removes the key from UserDefaults (raw and Codable Optional).
- External writes:
   - Updates are coalesced per runloop turn to avoid flooding.
   - If an external write results in the same value currently held, no publication occurs.
   - Raw type mismatch or invalid Codable data falls back to the key’s default. A publication occurs only if the value actually changes.
- Suite scoping (KVO-based, per-key):
   - Observation is keyed to the *suite* of the UserDefaults container provided to the key, not the specific instance: writes through another `UserDefaults` object of the same suite — including writes from other processes sharing an app-group suite (widgets, extensions) — are observed.
   - Writes to *other* keys never wake the wrapper.
   - Key names must be KVC-compliant for observation to work: no "." and no leading "@" (see Known limitations).

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
let key = DefaultsKey<Int>("react-count", default: 0, container: suite)

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
let key = DefaultsKey<String?>("react-name", default: nil, container: suite)

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
    "react-settings",
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
    "react-settings",
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
- Observation is KVO-based and **per-key**: writes to other keys never wake your streams or wrappers.
- Suite scoping: streams observe the *suite* of the provided UserDefaults container. Writes through a different `UserDefaults` instance of the same suite — and writes from other processes sharing an app-group suite (e.g. widgets/extensions) — are observed.
- No-op writes are coalesced by UserDefaults: setting a key to a value equal to the one already stored does not fire observation.

## Additional APIs

### Eager activation

Call `activateDefaultsBindings()` once in your `ObservableObject`'s `init` to install change-forwarding for **all** of its `@ObservableUserDefault` properties up front (see the note under [`@ObservableUserDefault`](#observableuserdefault)). This replaces the per-property `_ = myProperty` idiom.

### Raw storage of enums, URL, and UUID

`TransformedDefaultsKey` persists a value that is not itself a property-list type by storing a property-list representation of it — without the JSON-blob cost of `CodableDefaultsKey`:

```swift
enum Theme: String { case light, dark, system }

// Stored as the raw String "dark" (not JSON):
let themeKey = TransformedDefaultsKey(rawRepresentable: "theme", default: Theme.system)
let urlKey   = TransformedDefaultsKey(url: "homepage", default: URL(string: "https://example.com")!)   // absoluteString
let idKey    = TransformedDefaultsKey(uuid: "device-id", default: UUID())                                // uuidString

themeKey.set(.dark)
let theme = themeKey.get()                  // .dark
let vmKey = ObservableUserDefault(themeKey) // also works inside @ObservableUserDefault
```

`get()`/`set()`/`reset()`/`updates()`/`distinctUpdates()` are available, and an `@ObservableUserDefault` initializer accepts a `TransformedDefaultsKey`. An unknown stored raw value (e.g. an enum case that no longer exists) falls back to the key's default. You can also supply custom `encode`/`decode` transforms via the designated initializer. (Note: this representation is **not** the archived format `@AppStorage` uses for `URL`.)

### reset() / isStored

```swift
key.set(5)
key.isStored   // true
key.reset()    // removes the stored value; reads now return the default
key.isStored   // false
```

Available on `DefaultsKey`, `CodableDefaultsKey`, and `TransformedDefaultsKey`.

### App-group helper

```swift
guard let shared = UserDefaults.appGroup("group.com.example.app") else { return }
let key = DefaultsKey("flag", default: false, container: shared)
```

Prefer this over `UserDefaults(suiteName:)!` — the force-unwrap is a crash hazard when an extension's App Groups entitlement is misconfigured.

### Debounced async updates

Combine consumers can chain `.debounce`/`.throttle` on `publisher()`; for the async streams use `debouncedUpdates(for:)` (available on `DefaultsKey` and `CodableDefaultsKey`):

```swift
for await value in key.debouncedUpdates(for: .milliseconds(300)) {
    // fires only after 300ms of quiet — good for rate-limiting expensive reactions
}
```

### Using `@Observable` (Observation framework)

`@ObservableUserDefault` targets `ObservableObject` by design. If your app uses the `@Observable` macro (iOS 17+), drive a plain `@Observable` property from a key's `distinctUpdates()` stream and write back with `set(_:)`. See `Examples/06_ObservableMacroRecipe.swift` for the full recipe.

## Known limitations

- Key names must be KVC-compliant for observation
  - Observation is KVO-based; keys containing "." are interpreted by KVO as nested key paths and **will never fire** observation (keys must also not start with "@").
  - A debug assertion flags such keys; in release builds observation silently never fires for them. Plain `get()`/`set()` work with any key name.
  - Recommendation: use "-" or "_" as separators in key names (e.g. `"feature-flag"`, not `"feature.flag"`).

- Coalescing and “latest value” semantics
  - Observable wrappers and async sequences coalesce external changes per runloop turn; you may only receive the last value of a burst.
  - “Distinct” variants remove duplicate consecutive values by design.
  - Writes that don’t change the stored bytes don’t fire observation at all (UserDefaults-level KVO coalescing).
  - Treat streams as “latest value” feeds, not an event log.

- Suite scoping
  - Streams and wrappers observe the suite of the provided container (not `.standard` unless you explicitly use it). Different suites are fully isolated even for identical key names.

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
  - Because a missing key and a stored `nil` are indistinguishable, an Optional key's default should normally be `nil`. With a **non-nil** default (e.g. `DefaultsKey<Int?>("k", default: 5)`), a stored `nil` collapses back to `5` on the next read and cannot be observed durably.

- One `DefaultsKey` per key name / NSNumber bridging
  - A given UserDefaults key name should be owned by exactly one `DefaultsKey` type. `UserDefaults` stores `Int`/`Bool`/`Double` as `NSNumber`, which bridges leniently at the `0`/`1` boundary: a value written as `Bool true` reads back through an `Int` key as `1`, and `Int 1` reads through a `Bool` key as `true`. This is inherited Foundation behavior (shared with `@AppStorage`) and only surfaces if two keys share a name with different value types.

- Performance and payload size
  - `UserDefaults` is optimized for small values and infrequent writes.
  - Avoid storing large payloads (e.g., large JSON blobs or images). Prefer files/DB for large data.

- Main-actor mutation model
  - VMDefaults’ observable wrappers mutate view-model state on the main actor to preserve SwiftUI correctness.
  - External writes from background threads are fine, but UI-bound state changes are delivered on the main actor.

- Supported raw types
  - Raw (non-Codable) keys are limited to the package's `PropertyListValue` types: `String`, `Int`, `Double`, `Bool`, `Data`, `Date`, and arrays/dictionaries of **non-optional** values, plus a top-level optional thereof. Collection-of-optional and nested-optional shapes are compile errors (see [Supported types](#supported-types)).
  - For enums, `URL`, and `UUID`, use [`TransformedDefaultsKey`](#raw-storage-of-enums-url-and-uuid) (raw storage) or a `CodableDefaultsKey`.

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
                DefaultsKey("onboarding-complete", default: false, container: container)
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
        suite.set(true, forKey: "onboarding-complete")
    }
```

- Strict Sendable boundaries
   - Key types (e.g., DefaultsKey, CodableDefaultsKey) and stored values are Sendable when their Value is Sendable.
   - Codable encoding/decoding is performed on the calling context; wrapper-driven publications are main-actor confined.

- Reactive APIs honor actor isolation
   - UI-facing emissions are delivered on the main actor when sourced from the observable wrapper.
   - Async sequences (updates() / distinctUpdates()) are safe to iterate from @MainActor contexts. If you iterate off-main, hop to the main actor before mutating UI-bound state.

```swift
let key = DefaultsKey<Int>("react-count", default: 0, container: .standard)

    Task.detached {
        for await value in key.distinctUpdates() {
            await MainActor.run {
                // Safely update UI-bound state here
                // e.g., viewModel.someDerivedValue = value
            }
        }
    }
```

- Cross-instance and cross-process synchronization
   - Observation is KVO-based and suite-scoped: components bound to different `UserDefaults` instances of the same suite stay in sync, and writes from other processes sharing an app-group suite (widgets, extensions) are observed.
   - **Same-process** writes are delivered synchronously on the writing thread (VMDefaults then hops to the main actor). **Cross-process** delivery is different: it is mediated by the preferences daemon (`cfprefsd`), so it is asynchronous and *eventually* consistent — most reliable in the foreground and not guaranteed while a process is suspended/backgrounded. Treat cross-process streams as a "latest value" feed, not a real-time event log.
   - Within a process, sharing a single injected `UserDefaults` instance is still good practice but no longer required for synchronization.

## Testing

Run the suite with:

```sh
swift test
```

The package is continuously built and tested on macOS via GitHub Actions (see `.github/workflows/ci.yml`), with warnings treated as errors so the strict-concurrency contract cannot silently regress.

Writing tests against your own view models is straightforward because every key takes an injectable `UserDefaults` container. Give each test an isolated suite so cases don't bleed into `.standard` or each other:

```swift
func makeIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "MyAppTests.\(UUID().uuidString)")!
}

@MainActor
func testCounterIncrements() {
    let defaults = makeIsolatedDefaults()
    let vm = CounterVM(container: defaults)
    vm.increment()
    #expect(vm.count == 1)
}
```

You can also rebind a production key to a test container with `key.with(container:)`, and assert reactive behavior by observing `objectWillChange` or by collecting from `updates()` / `publisher()`.
