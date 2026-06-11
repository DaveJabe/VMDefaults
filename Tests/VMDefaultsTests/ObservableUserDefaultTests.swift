//
//  ObservableUserDefaultTests.swift
//  VMDefaults
//
//  Created by Assistant on 1/10/26.
//

import Foundation
import Testing
import Combine
@testable import VMDefaults

@Suite("VMDefaults - ObservableUserDefault")
struct ObservableUserDefaultTests {

    @Test("Default value when missing")
    @MainActor
    func defaultValueWhenMissing() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)

        let vm = ObservableVM(key)

        #expect(vm.value == nil)
        #expect(defaults.object(forKey: key.name) == nil)
    }

    @Test("Local write publishes and persists")
    @MainActor
    func localWritePublishesAndPersists() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        vm.value = "ABC"

        #expect(await waiter.value)
        #expect(vm.value == "ABC")
        #expect(defaults.string(forKey: key.name) == "ABC")
    }

    @Test("External write publishes and updates")
    @MainActor
    func externalWritePublishesAndUpdates() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        let waiter = startWillChangeWaiter(vm)
        await yieldForSubscriptionInstall()

        defaults.set("XYZ", forKey: key.name)

        #expect(await waiter.value)
        #expect(vm.value == "XYZ")
    }

    @Test("Optional nil removes key")
    @MainActor
    func optionalNilRemovesKey() {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("pinnedID", default: nil, container: defaults)
        let vm = ObservableVM(key)

        vm.value = "AAA"
        #expect(defaults.string(forKey: key.name) == "AAA")

        vm.value = nil
        #expect(defaults.object(forKey: key.name) == nil)
        #expect(vm.value == nil)
    }

    @Test("Multiple VMs stay in sync")
    @MainActor
    func multipleVMsStayInSync() async {
        let defaults = makeIsolatedDefaults()
        let key = DefaultsKey<String?>("shared", default: nil, container: defaults)

        let a = ObservableVM(key)
        let b = ObservableVM(key)

        let waiter = startWillChangeWaiter(b)
        await yieldForSubscriptionInstall()

        a.value = "SYNC"

        #expect(await waiter.value)
        #expect(b.value == "SYNC")
    }

    @Test("Primitive round-trips: Int, Bool, Double")
    @MainActor
    func primitivesRoundTrip() async {
        let defaults = makeIsolatedDefaults()

        let intKey = DefaultsKey<Int>("int", default: 0, container: defaults)
        let boolKey = DefaultsKey<Bool>("bool", default: false, container: defaults)
        let doubleKey = DefaultsKey<Double>("double", default: 0.0, container: defaults)

        let intVM = ObservableVM(intKey)
        let boolVM = ObservableVM(boolKey)
        let doubleVM = ObservableVM(doubleKey)

        #expect(intVM.value == 0)
        #expect(boolVM.value == false)
        #expect(doubleVM.value == 0.0)

        intVM.value = 42
        boolVM.value = true
        doubleVM.value = 3.14159

        #expect(defaults.integer(forKey: intKey.name) == 42)
        #expect(defaults.bool(forKey: boolKey.name) == true)
        #expect(abs(defaults.double(forKey: doubleKey.name) - 3.14159) < 1e-9)

        let intWait = startWillChangeWaiter(intVM)
        let boolWait = startWillChangeWaiter(boolVM)
        let doubleWait = startWillChangeWaiter(doubleVM)
        await yieldForSubscriptionInstall()

        defaults.set(7, forKey: intKey.name)
        defaults.set(false, forKey: boolKey.name)
        defaults.set(2.71828, forKey: doubleKey.name)

        #expect(await intWait.value)
        #expect(await boolWait.value)
        #expect(await doubleWait.value)

        #expect(intVM.value == 7)
        #expect(boolVM.value == false)
        #expect(abs(doubleVM.value - 2.71828) < 1e-9)
    }
}
