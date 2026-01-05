# VMDefaults Examples

This folder contains small, focused code snippets that demonstrate how to use VMDefaults.

These files are not part of the library target by default. You can:
- Open them for reference, or
- Add them to a sample app target / playground to run the snippets.

## Files:
- 01_DefiningKeys.swift — Create strongly-typed `DefaultsKey` values (raw, optional, Codable, and custom containers)
- 02_NonObservableAccessors.swift — Read current values using `get()` and `get(decoder:onError:)`
- 03_CombineExamples.swift — Subscribe to updates using Combine (`publisher` / `distinctPublisher`)
- 04_AsyncSequenceExamples.swift — Observe updates using async/await (`updates` / `distinctUpdates`)
- 05_ObservableUserDefaultExamples.swift — Use `@ObservableUserDefault` inside `ObservableObject` view models (raw and Codable)

Tip: For experimentation, consider using a dedicated `UserDefaults` suite to avoid writing to `.standard`:

```swift
let isolated = UserDefaults(suiteName: "VMDefaults.Examples")!
```
