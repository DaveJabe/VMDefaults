//
//  ObservableForwarding.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine
import ObjectiveC.runtime

final class _DefaultsBindingToken {
    var cancellable: AnyCancellable?
    var isInternalWrite = false
}

private final class _DefaultsBindingStorage {
    var tokensByID: [String: _DefaultsBindingToken] = [:]
}

@MainActor
private var _defaultsBindingStorageKey: UInt8 = 0

@MainActor
func _token(on instance: AnyObject, id: String) -> _DefaultsBindingToken {
    let storage: _DefaultsBindingStorage
    if let existing = objc_getAssociatedObject(instance, &_defaultsBindingStorageKey) as? _DefaultsBindingStorage {
        storage = existing
    } else {
        let newStorage = _DefaultsBindingStorage()
        objc_setAssociatedObject(instance, &_defaultsBindingStorageKey, newStorage, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        storage = newStorage
    }

    if let existing = storage.tokensByID[id] { return existing }
    let token = _DefaultsBindingToken()
    storage.tokensByID[id] = token
    return token
}
