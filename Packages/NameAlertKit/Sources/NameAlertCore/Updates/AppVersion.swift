import Foundation

/// A dotted numeric version such as "1.0.2". Components compare as numbers and a missing one counts as zero, so "1.0"
/// equals "1.0.0" and "1.10" is newer than "1.9". The build number is not part of it.
public struct AppVersion: Comparable, Sendable {
    public let components: [Int]

    /// Nil for an empty string, or when any component is not all digits ("1.0.1b", "2.0-beta", "1..2"), so a version
    /// that cannot be read is never treated as newer.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    public init(_ os: OperatingSystemVersion) {
        components = [os.majorVersion, os.minorVersion, os.patchVersion]
    }

    /// True when `candidate` is a higher version than `current`. False when either one cannot be read.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = AppVersion(candidate), let current = AppVersion(current) else { return false }
        return candidate > current
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }
}
