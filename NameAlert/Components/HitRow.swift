import Foundation
import NameAlertCore
import SwiftUI

/// One mention on a line: when it was heard, the word in bold, and what was said around it.
struct HitRow: View {
    let hit: Hit
    var now: Date = Date()

    static let timeWidth: CGFloat = 60
    static let termWidth: CGFloat = 76

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: Self.time(of: hit.timestamp, now: now))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.timeWidth, alignment: .leading)
            Text(verbatim: hit.term)
                .bold()
                .lineLimit(1)
                .frame(width: Self.termWidth, alignment: .leading)
            Text(verbatim: Self.focusedContext(of: hit))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "10:32" for today, "Oct 9" before that.
    static func time(of date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The context from a couple of words before the match on. The context holds about eight words on each side of
    /// the match, so cutting its middle or its end would hide the very words that were heard; starting just before
    /// them keeps them in view, and a narrow row cuts only the end.
    static func focusedContext(of hit: Hit, wordsBefore: Int = 2) -> String {
        let context = hit.context
        let heard = hit.matchedText.isEmpty ? hit.term : hit.matchedText
        guard let match = context.range(of: heard, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return context
        }
        let before = context[..<match.lowerBound].split(whereSeparator: \.isWhitespace)
        guard before.count > wordsBefore else { return context }
        return "…" + before.suffix(wordsBefore).joined(separator: " ") + " " + context[match.lowerBound...]
    }

    /// What VoiceOver reads for the row.
    static func accessibilityLabel(for hit: Hit) -> String {
        let when = hit.timestamp.formatted(date: .abbreviated, time: .shortened)
        return "Heard \(hit.term) at \(when): \(hit.context)"
    }
}
