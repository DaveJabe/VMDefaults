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

// Dedicated suite to avoid polluting standard defaults
let combineSuite = UserDefaults(suiteName: "VMDefaults.Examples.Combine")!

let combineKey = DefaultsKey<Int>("combine.counter", default: 0, container: combineSuite)

var combineCancellables: Set<AnyCancellable> = []

@MainActor
func demoCombinePublishers() {
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

    // Produce some changes
    combineSuite.set(1, forKey: combineKey.name)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: combineSuite)

    combineSuite.set(1, forKey: combineKey.name)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: combineSuite)

    combineSuite.set(2, forKey: combineKey.name)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: combineSuite)
}

