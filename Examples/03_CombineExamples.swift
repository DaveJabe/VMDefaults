//
//  03_CombineExamples.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//
// Examples showing Combine publishers with VMDefaults

import Foundation
import Combine
import VMDefaults

// Dedicated suite to avoid polluting standard defaults.
// `nonisolated(unsafe)`: UserDefaults is thread-safe but not `Sendable`, so a global needs the opt-out.
nonisolated(unsafe) let combineSuite = UserDefaults(suiteName: "VMDefaults.Examples.Combine")!

let combineKey = DefaultsKey<Int>("combine-counter", default: 0, container: combineSuite)

@MainActor
func demoCombinePublishers() {
    var combineCancellables: Set<AnyCancellable> = []

    // Subscribe to distinctPublisher to avoid duplicate consecutive values
    combineKey.distinctPublisher()
        .sink { value in
            print("[Combine] distinct value:", value)
        }
        .store(in: &combineCancellables)

    // Also show the raw publisher (no removeDuplicates())
    combineKey.publisher()
        .sink { value in
            print("[Combine] raw value:", value)
        }
        .store(in: &combineCancellables)

    // Produce some changes. Note: UserDefaults coalesces no-op writes at the KVO level,
    // so re-setting the same value does not fire observation at all.
    combineSuite.set(1, forKey: combineKey.name)
    combineSuite.set(2, forKey: combineKey.name)

    _ = combineCancellables // keep subscriptions alive for the duration of this snippet
}

