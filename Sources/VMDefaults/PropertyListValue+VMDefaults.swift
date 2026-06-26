import Foundation

/// Marker protocol for values that can be stored directly in UserDefaults as property-list types.
public protocol PropertyListValue {}

/// Marker for property-list values that are **not** `Optional`.
///
/// Collection *elements* are constrained to this (rather than to `PropertyListValue`) so that
/// shapes like `[Int?]`, `[String: Int?]`, and `Int??` — which are legal property-list *types*
/// only at the top level — become compile-time errors instead of runtime crashes.
///
/// Why this matters: an `Array`/`Dictionary` whose elements are `Optional` round-trips through
/// `UserDefaults.set(_:forKey:)` as a CoreFoundation property list containing a null, which
/// `_CFPrefsValidateValueForKey` rejects by calling `abort()` (a hard process termination, in
/// release builds too). A *top-level* Optional is fine because VMDefaults maps `nil` to
/// `removeObject(forKey:)` before it ever reaches CoreFoundation. Constraining elements to
/// `NonOptionalPropertyListValue` turns the dangerous shapes into compile errors while leaving
/// `[Int]`, `[[Int]]`, `[String: [Int]]`, `Int?`, and `[Int]?` fully supported.
public protocol NonOptionalPropertyListValue: PropertyListValue {}

// Primitive property-list types (all non-optional).
extension String: NonOptionalPropertyListValue {}
extension Int: NonOptionalPropertyListValue {}
extension Double: NonOptionalPropertyListValue {}
extension Bool: NonOptionalPropertyListValue {}
extension Data: NonOptionalPropertyListValue {}
extension Date: NonOptionalPropertyListValue {}

// Collections: elements/values must themselves be *non-optional* property-list values.
extension Array: PropertyListValue, NonOptionalPropertyListValue where Element: NonOptionalPropertyListValue {}
extension Dictionary: PropertyListValue, NonOptionalPropertyListValue where Key == String, Value: NonOptionalPropertyListValue {}

// Optional is supported only at the *top level* (its `nil` maps to `removeObject`), so its
// `Wrapped` must be non-optional — which also makes nested optionals (`Int??`) unrepresentable.
extension Optional: PropertyListValue where Wrapped: NonOptionalPropertyListValue {}
