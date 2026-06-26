//
//  06_ObservableMacroRecipe.swift
//  VMDefaults
//
//  Created by David Jabech on 6/26/26.
//
// @ObservableUserDefault is bound to ObservableObject by design. If your app uses the newer
// @Observable macro (Observation framework, iOS 17+), you can still get UserDefaults-backed,
// cross-process-observed state by driving a plain @Observable property from a key's
// `distinctUpdates()` stream and writing back with `set(_:)`. This recipe shows the bridge.

import Foundation
import Observation
import VMDefaults

// `nonisolated(unsafe)`: UserDefaults is thread-safe but not `Sendable`, so a global needs the opt-out.
nonisolated(unsafe) let observableMacroSuite = UserDefaults(suiteName: "VMDefaults.Examples.ObservableMacro")!

@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
@MainActor
@Observable
final class ThemeStore {
    /// The SwiftUI-observed property. Updated locally and from external/cross-process writes.
    private(set) var themeName: String

    @ObservationIgnored
    private let key = DefaultsKey<String>("om-theme", default: "system", container: observableMacroSuite)

    @ObservationIgnored
    private var bridge: Task<Void, Never>?

    init() {
        themeName = key.get()

        // Bridge external UserDefaults changes into the @Observable property.
        let stream = key.distinctUpdates()
        bridge = Task { @MainActor [weak self] in
            for await value in stream {
                self?.themeName = value
            }
        }
    }

    /// Local mutation: persist, then reflect immediately (don't wait for the async stream).
    func setTheme(_ name: String) {
        key.set(name)
        themeName = name
    }

    deinit { bridge?.cancel() }
}
