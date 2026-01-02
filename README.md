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
    - [`@ObservableUserDefault`](#observableuserdefault)
    - [`@CodableUserDefault`](#codableuserdefault)
    - [Error handling (optional)](#error-handling-optional)
    - [Migrating from @AppStorage](#migrating-from-appstorage)
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
- SwiftUI and `ObservableObject`
- Apple platforms that support SwiftUI and `UserDefaults`

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
Defines a strongly-typed UserDefaults key:

```
enum AppDefaults {
    static let pinnedID = DefaultsKey<String?>(
        "pinnedID",
        default: nil
    )
}
```

You can also provide a custom container:

```
DefaultsKey<Int>(
    "counter",
    default: 0,
    container: UserDefaults(suiteName: "group.myapp")!
)
```

#### `@ObservableUserDefault`

For property-list compatible values
(String, Int, Bool, Double, Data, and optionals)

Example
```
final class HomeViewModel: ObservableObject {
    @ObservableUserDefault(AppDefaults.pinnedID)
    var pinnedID: String?
}
```
### Behavior

Local assignment:
- persists to UserDefaults
- triggers objectWillChange

External writes:
- update the property
- trigger objectWillChange

Assigning nil to an optional:
- removes the key from UserDefaults

SwiftUI usage

```
struct HomeView: View {
    @StateObject var vm = HomeViewModel()

    var body: some View {
        Text(vm.pinnedID ?? "None")
    }
}
```

### `@CodableUserDefault`

For Codable values stored as JSON-encoded Data.

Example:
```
struct Settings: Codable, Equatable {
    var count: Int
    var name: String
}
```
```
final class SettingsViewModel: ObservableObject {
    @CodableUserDefault(
        DefaultsKey(
            "settings",
            default: Settings(count: 0, name: "zero")
        )
    )
    var settings: Settings
}
```

### Error handling (optional)

Provide an error handler per wrapper:

```
@CodableUserDefault(
    AppDefaults.settings,
    onError: { error in
        print("Failed to encode/decode settings:", error)
    }
)
var settings: Settings
```

Or define a global default (main-actor isolated):

```
VMDefaultsCoding.defaultOnError = { error in
    print(error)
}
```

If decoding fails, the wrapper falls back to the default value.

### Migrating from @AppStorage
#### View-based usage (no change needed)

If your state lives in the view, keep using @AppStorage.

```
struct ProfileView: View {
    @AppStorage("username") var username = ""
}
```

### Moving state into a view model

Replace @AppStorage with @ObservableUserDefault.

#### Before

```
struct HomeView: View {
    @AppStorage("pinnedID") var pinnedID: String?
}
```

#### After

```
final class HomeViewModel: ObservableObject {
    @ObservableUserDefault(
        DefaultsKey("pinnedID", default: nil)
    )
    var pinnedID: String?
}

struct HomeView: View {
    @StateObject var vm = HomeViewModel()
}
```

## Concurrency model

- All mutation occurs on MainActor
- UserDefaults.didChangeNotification is:
    - observed
    - coalesced
    - re-read safely on the main actor
- No non-isolated global mutable state
- Clean Swift 6 concurrency diagnostics

## Testing

The package includes comprehensive tests for:
- Local writes
- External writes
- Multiple view models syncing
- Optional removal semantics
- Codable decode failures
- High-volume updates
- Concurrent write scenarios

###### Tests use isolated UserDefaults suites to avoid cross-test pollution.
