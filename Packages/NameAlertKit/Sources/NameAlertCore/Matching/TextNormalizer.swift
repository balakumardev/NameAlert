import Foundation

/// One word found in a text.
public struct Token: Sendable, Equatable {
    /// The word with case, accents and character width folded away. Never empty.
    public let normalized: String
    /// Where the word sits in the string it was read from. It covers the apostrophes inside the word ("don't")
    /// and leaves out a possessive `'s`.
    public let range: Range<String.Index>
}

/// Splits text into comparable words. What is heard and what the user typed go through the same steps,
/// so "Café", "CAFE" and "cafe" are one word.
public enum TextNormalizer {
    /// Splits `text` into words, each pointing back into `text`.
    ///
    /// A word is a maximal run of Unicode letters and digits. Combining marks stay inside the word they
    /// follow. An apostrophe (`'` or `’`) between two letters stays inside the word but is left out of its
    /// normalized form, so "don't" is the word "dont" and "O’Brien" is "obrien". A possessive `'s` or `’s`
    /// that follows a letter and ends the word is dropped, so "Bala's" is the word "bala". Everything else
    /// between words is a separator.
    public static func tokenize(_ text: String) -> [Token] {
        let scalars = text.unicodeScalars
        var tokens: [Token] = []
        var wordStart: String.Index?
        var wordEndsInLetter = false  // the word being read ends in a letter or mark, so an apostrophe may follow
        var wordHasApostrophe = false  // the word being read has an apostrophe inside, which is not part of its text
        var index = scalars.startIndex

        func closeWord(at end: String.Index) {
            guard let start = wordStart else { return }
            let range = start..<end
            let word =
                wordHasApostrophe
                ? String(scalars[range].filter { !isApostrophe($0) })
                : String(text[range])
            let normalized = fold(word)
            if !normalized.isEmpty { tokens.append(Token(normalized: normalized, range: range)) }
            wordStart = nil
            wordHasApostrophe = false
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let kind = ScalarKind(scalar)
            // A mark continues a word but never starts one.
            if kind == .letter || kind == .number || (kind == .mark && wordStart != nil) {
                if wordStart == nil { wordStart = index }
                wordEndsInLetter = kind != .number
                index = scalars.index(after: index)
                continue
            }
            if wordStart != nil, wordEndsInLetter, isApostrophe(scalar) {
                // After a letter, a possessive 's ends the word and an apostrophe before a letter is part of it.
                if let afterPossessive = endOfPossessive(at: index, in: scalars) {
                    closeWord(at: index)
                    index = afterPossessive
                    continue
                }
                let next = scalars.index(after: index)
                if next < scalars.endIndex, ScalarKind(scalars[next]) == .letter {
                    wordHasApostrophe = true
                    index = next
                    continue
                }
            }
            closeWord(at: index)  // a separator ends the word being read, if there is one
            index = scalars.index(after: index)
        }
        closeWord(at: scalars.endIndex)
        return tokens
    }

    /// The normalized words of `text`, without their positions.
    public static func tokens(_ text: String) -> [String] {
        tokenize(text).map(\.normalized)
    }

    /// A typed term as the words it must match: "Stand-Up" is `["stand", "up"]`. Empty when the term has no
    /// letters or digits.
    public static func normalizeTerm(_ term: String) -> [String] {
        tokens(term)
    }

    /// `text` with case, accents and character width folded away. Plain ASCII only needs lowercasing, which
    /// is what the library call would give, so it skips the (much slower) folding.
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    private static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "'" || scalar == "\u{2019}"
    }

    /// Where a possessive `'s` / `’s` starting at `index` ends, or `nil` when there is none there.
    /// The `s` must end the word: in "Bala'sh" the apostrophe is not a possessive.
    private static func endOfPossessive(at index: String.Index, in scalars: String.UnicodeScalarView) -> String.Index? {
        guard isApostrophe(scalars[index]) else { return nil }
        let s = scalars.index(after: index)
        guard s < scalars.endIndex, scalars[s] == "s" || scalars[s] == "S" else { return nil }
        let after = scalars.index(after: s)
        if after < scalars.endIndex, ScalarKind(scalars[after]) != .other { return nil }
        return after
    }
}

/// What a scalar is to the tokenizer.
private enum ScalarKind {
    case letter, mark, number, other

    init(_ scalar: Unicode.Scalar) {
        if scalar.isASCII {  // the common case, without the Unicode table lookup
            switch scalar.value {
            case 0x30...0x39: self = .number
            case 0x41...0x5A, 0x61...0x7A: self = .letter
            default: self = .other
            }
            return
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: self = .letter
        case .nonspacingMark, .spacingMark, .enclosingMark: self = .mark
        case .decimalNumber, .letterNumber, .otherNumber: self = .number
        default: self = .other
        }
    }
}
