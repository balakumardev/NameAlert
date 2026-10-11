import Foundation

// Helpers that let a settings struct start from its property defaults and take only what decodes cleanly.
// A config written by a newer app version, or edited by hand, then loses at most the single field it got
// wrong, instead of failing to load at all.

extension KeyedDecodingContainer {
    /// Overwrites `target` with the value stored under `key`.
    ///
    /// A missing key, `null`, or a value that cannot be decoded as `Value` (wrong type, unknown enum raw
    /// value) leaves `target` unchanged, so the property default survives.
    func decodeTolerantly<Value: Decodable>(into target: inout Value, forKey key: Key) {
        if let value = try? decodeIfPresent(Value.self, forKey: key) {
            target = value
        }
    }

    /// Same as `decodeTolerantly(into:forKey:)` for a set stored as an array of raw strings.
    ///
    /// Entries that are not known cases (for example a channel added by a newer version) are dropped.
    /// A present array always wins over the default, so an empty array stays empty.
    func decodeTolerantly<Element: RawRepresentable & Hashable>(intoSet target: inout Set<Element>, forKey key: Key)
    where Element.RawValue == String {
        if let names = try? decodeIfPresent([String].self, forKey: key) {
            target = Set(names.compactMap(Element.init(rawValue:)))
        }
    }

    /// Same as `decodeTolerantly(into:forKey:)` for an array of structs, decoded one element at a time.
    ///
    /// An element that cannot be decoded as `Element` (null, a non-object, or an object missing a required
    /// key) is skipped and the others keep their order, so one bad entry never takes the rest down with it.
    /// A missing key, `null`, or a value that is not an array leaves `target` unchanged.
    func decodeTolerantly<Element: Decodable>(intoElements target: inout [Element], forKey key: Key) {
        if let wrapped = try? decodeIfPresent([Lossy<Element>].self, forKey: key) {
            target = wrapped.compactMap(\.element)
        }
    }
}

/// Decodes to `nil` instead of throwing, so an unkeyed container always moves on to the next element.
private struct Lossy<Element: Decodable>: Decodable {
    let element: Element?

    init(from decoder: any Decoder) {
        element = try? Element(from: decoder)
    }
}

extension Double {
    /// `self` limited to `range`.
    ///
    /// NaN slips through `min`/`max` and cannot be written as JSON, so it becomes the lower bound.
    func clamped(to range: ClosedRange<Double>) -> Double {
        isNaN ? range.lowerBound : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
