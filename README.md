# VMDefaults

A SwiftUI-friendly, Swift 6–safe way to bind `UserDefaults` to `ObservableObject` view models.

VMDefaults provides lightweight property wrappers that:

- Persist values to `UserDefaults`
- Reactively update SwiftUI views via `ObservableObject`
- Stay in sync across multiple view models
- Correctly handle external `UserDefaults` writes
- Compile cleanly under Swift 6's strict concurrency rules

This package is intentionally small, explicit, and boring — in the best way.

---

## Why this exists

SwiftUI gives us:

- `@AppStorage` — excellent for views
- `@Observable` — excellent for new architectures

But there’s a gap when you want:

- `ObservableObject` (still extremely common)
- View-model-owned state
- Persistence via `UserDefaults`
- Reactive updates when another screen / view model / system write mutates the same key

VMDefaults fills that gap without:

- Global mutable state
- `NotificationCenter` logic in your view models
- Manual `objectWillChange.send()`
- Race conditions under Swift 6

---

## What this package is (and isn’t)

### This package is

- A UserDefaults → ObservableObject bridge
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

- Your state lives directly in views — use `@AppStorage`.
- You are fully on `@Observable` — the Observation macro already handles invalidation automatically. This package exists specifically for `ObservableObject`.
- You need high-volume or transactional persistence — `UserDefaults` is not suitable for large datasets, frequent writes, or atomic multi-key updates. Use SQLite, GRDB, Core Data, etc.
- You want background-thread mutation of view-model state — all mutation in this package intentionally happens on the main actor to preserve SwiftUI correctness.

---

## Installation

### Swift Package Manager

Add the package dependency to your `Package.swift`:

```swift
.package(
    url: "https://github.com/yourname/VMDefaults.git",
    from: "0.1.0"
)

