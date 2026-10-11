import Foundation
import NameAlertCore
import SwiftUI

/// Marks the words a rule listens for inside a text: bold, on the accent color. The match tester, the live transcript
/// and the history details all mark words the same way.
enum TextHighlighting {
    /// Where `matches` are in `text`, in reading order. A match is the words as they were written, so each is looked
    /// for after the one before it; one that is not found (the text changed since) is skipped.
    static func ranges(of matches: [MatchResult], in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var from = text.startIndex
        for match in matches {
            guard !match.matchedText.isEmpty,
                let found = text.range(of: match.matchedText, range: from..<text.endIndex)
            else { continue }
            ranges.append(found)
            from = found.upperBound
        }
        return ranges
    }

    /// `text` with `ranges` marked. `font` is the font of the text around them, which the marked words use in bold.
    static func marked(_ text: String, ranges: [Range<String.Index>], font: Font = .body) -> AttributedString {
        var marked = AttributedString(text)
        for range in ranges {
            guard let attributedRange = Range(range, in: marked) else { continue }
            marked[attributedRange].font = font.bold()
            marked[attributedRange].backgroundColor = Color.accentColor.opacity(0.3)
        }
        return marked
    }

    /// `text` with every word the enabled `rules` listen for marked. A rule that is off will not alert, so what it
    /// would have matched is left alone. Matches of different rules may overlap; the overlap is marked once.
    static func highlighted(_ text: String, rules: [Rule], font: Font = .body) -> AttributedString {
        let found = rules.filter(\.isEnabled).flatMap { rule in
            Self.ranges(of: RuleEngine.matches(in: text, rule: rule), in: text)
        }
        return marked(text, ranges: found, font: font)
    }

    /// The places in `text` where `word` stands as a word of its own, ignoring case and accents: "Bala" is in
    /// "thanks Bala, that helps" and not in "Balance".
    static func occurrences(of word: String, in text: String) -> [Range<String.Index>] {
        let needle = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
            let range = text.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex)
        {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !isPartOfWord(before), !isPartOfWord(after) { found.append(range) }
            from = range.upperBound
        }
        return found
    }

    private static func isPartOfWord(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }
}
