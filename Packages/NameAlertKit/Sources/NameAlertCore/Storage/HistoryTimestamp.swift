import Foundation

/// How a hit's timestamp is written in `history.json`: ISO-8601 in UTC with milliseconds, like
/// `2025-10-11T09:30:00.123Z`.
///
/// The milliseconds are worked out here, with whole-number arithmetic, instead of by a Foundation formatter. `Date`
/// equality is exact, and the formatters do not agree on how to round a time like `...00.123`, which a `Double`
/// holds as `...00.12299990654` (`Date.ISO8601FormatStyle` cuts it to `.122`). So the result does not depend on how
/// a macOS version rounds: a date that is a whole number of milliseconds comes back equal, and any other date comes
/// back rounded to the nearest millisecond. Foundation only handles the whole second.
enum HistoryTimestamp {
    /// `2025-10-11T09:30:00Z`: UTC, no fraction.
    private static let wholeSecond = Date.ISO8601FormatStyle()

    /// The first and last instants with a four-digit year, in seconds since 1970. Anything outside is clamped, so
    /// the conversion to whole numbers below can never trap and the text keeps its shape.
    private static let supportedSeconds: ClosedRange<Double> = -62_135_596_800...253_402_300_799

    static func string(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970.clamped(to: supportedSeconds)  // also makes NaN a real date
        let totalMilliseconds = Int64((seconds * 1000).rounded())
        var wholeSeconds = totalMilliseconds / 1000
        var milliseconds = totalMilliseconds % 1000
        if milliseconds < 0 {  // before 1970 the remainder counts backwards, but the fraction always counts forwards
            milliseconds += 1000
            wholeSeconds -= 1
        }

        let text = wholeSecond.format(Date(timeIntervalSince1970: Double(wholeSeconds)))
        // The fraction goes right after the seconds: "2025-10-11T09:30:00" is 19 characters, then "Z".
        guard let designator = text.firstIndex(of: "T"),
              let end = text.index(designator, offsetBy: 9, limitedBy: text.endIndex) else { return text }
        let digits = String(milliseconds)
        let fraction = "." + String(repeating: "0", count: 3 - digits.count) + digits
        return String(text[..<end]) + fraction + String(text[end...])
    }

    /// The date for `text`, or nil if it is not an ISO-8601 date and time. The fraction is optional and may have any
    /// number of digits (only the first six count), so files written without one still read.
    static func date(from text: String) -> Date? {
        guard let dot = text.firstIndex(of: ".") else { return try? wholeSecond.parse(text) }

        let digitCharacters: ClosedRange<Character> = "0"..."9"
        var end = text.index(after: dot)
        while end < text.endIndex, digitCharacters.contains(text[end]) {
            end = text.index(after: end)
        }
        let digits = text[text.index(after: dot)..<end].prefix(6)
        let rest = String(text[end...])
        // A second dot is garbage. (Some versions of the parser would take a fraction here and some would not.)
        guard !rest.contains("."), let fraction = Int64(digits),
              let whole = try? wholeSecond.parse(String(text[..<dot]) + rest) else { return nil }

        // Whole numbers up to the final division, which rounds once, correctly. That is what keeps the result
        // equal to the date that was written.
        let scale = digits.reduce(1.0) { result, _ in result * 10 }
        return Date(timeIntervalSince1970: (whole.timeIntervalSince1970 * scale + Double(fraction)) / scale)
    }
}
