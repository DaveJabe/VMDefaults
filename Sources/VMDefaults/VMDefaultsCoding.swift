//
//  VMDefaultsCoding.swift
//  VMDefaults
//
//  Created by David Jabech on 1/1/26.
//

import Foundation
import Combine

public enum VMDefaultsCoding {
    @MainActor
    public static var defaultOnError: (@Sendable (Error) -> Void)?
}
