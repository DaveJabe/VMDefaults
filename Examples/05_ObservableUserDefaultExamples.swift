//
//  05_ObservableUserDefaultExamples.swift
//  VMDefaults
//
//  Created by David Jabech on 1/4/26.
//
// Examples showing @ObservableUserDefault in view models

import Foundation
import Combine
import VMDefaults

// `nonisolated(unsafe)`: UserDefaults is thread-safe but not `Sendable`, so a global needs the opt-out.
nonisolated(unsafe) let obsSuite = UserDefaults(suiteName: "VMDefaults.Examples.Observable")!

// MARK: - Raw value example

@MainActor
final class CounterVM: ObservableObject {
    @ObservableUserDefault var count: Int

    init() {
        let key = DefaultsKey<Int>("obs-counter", default: 0, container: obsSuite)
        _count = ObservableUserDefault(key)
        _ = count // install binding eagerly for example prints
    }

    func increment() { count += 1 }
}

// MARK: - Codable value example

struct Profile: Codable, Equatable, Sendable { var name: String; var age: Int }

@MainActor
final class ProfileVM: ObservableObject {
    @ObservableUserDefault var profile: Profile

    init() {
        let key = CodableDefaultsKey<Profile>("obs-profile", default: .init(name: "Anonymous", age: 0), container: obsSuite)
        _profile = ObservableUserDefault(key)
        _ = profile
    }

    func updateName(_ name: String) { profile.name = name }
}

// MARK: - Demo functions

@MainActor
func demoObservableUserDefault() async {
    let counter = CounterVM()
    let profileVM = ProfileVM()

    // Observe immediate SwiftUI-style updates
    var cancels: Set<AnyCancellable> = []
    counter.objectWillChange.sink { print("[Observable] Counter will change") }.store(in: &cancels)
    profileVM.objectWillChange.sink { print("[Observable] Profile will change") }.store(in: &cancels)

    // Local writes
    counter.increment()
    profileVM.updateName("Taylor")

    // External writes (simulate another screen)
    obsSuite.set(10, forKey: DefaultsKey<Int>("obs-counter", default: 0, container: obsSuite).name)

    let extProfile = Profile(name: "Jordan", age: 28)
    if let data = try? JSONEncoder().encode(extProfile) {
        obsSuite.set(data, forKey: CodableDefaultsKey<Profile>("obs-profile", default: .init(name: "Anonymous", age: 0), container: obsSuite).name)
    }

    // Give the coalescing loop a moment to run in this demo context
    try? await Task.sleep(nanoseconds: 30_000_000)

    _ = cancels // keep alive in this snippet
}
