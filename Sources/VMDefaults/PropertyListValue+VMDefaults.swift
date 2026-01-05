import Foundation

/// Marker protocol for values that can be stored directly in UserDefaults as property-list types.
public protocol PropertyListValue {}

// Primitive property-list types
extension String: PropertyListValue {}
extension Int: PropertyListValue {}
extension Double: PropertyListValue {}
extension Bool: PropertyListValue {}
extension Data: PropertyListValue {}
extension Date: PropertyListValue {}

// Collections
extension Array: PropertyListValue where Element: PropertyListValue {}
extension Dictionary: PropertyListValue where Key == String, Value: PropertyListValue {}

// Optional wrapper
extension Optional: PropertyListValue where Wrapped: PropertyListValue {}

