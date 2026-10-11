import Foundation
import NameAlertCore  // not @testable: these tests see only what other modules see
import Testing

// Non-ASCII text is written with escapes so a tool that re-normalizes the file cannot change what is tested.

/// Rows of the task table: text and the words it must split into.
private let tokenRows: [(String, [String])] = [
    ("Hey Bala, can you share?", ["hey", "bala", "can", "you", "share"]),
    ("BALA's deck", ["bala", "deck"]),
    ("Bala\u{2019}s", ["bala"]),  // typographic apostrophe
    ("Caf\u{00E9} M\u{00FC}ller", ["cafe", "muller"]),  // "Café Müller"
    ("stand-up at 10", ["stand", "up", "at", "10"]),
    ("", []),
    ("!!! \u{1F642}", []),  // punctuation and an emoji are not words
    // Contractions (spec section 6): an apostrophe between two letters is dropped, it does not split the word.
    ("I don't know", ["i", "dont", "know"]),
    ("O\u{2019}Brien called", ["obrien", "called"]),
    ("Bala's deck", ["bala", "deck"]),  // a possessive is still dropped
]

/// Beyond the table: accents written as separate marks, full-width letters, where a possessive does not apply and
/// where an apostrophe does not sit between two letters.
private let tokenEdgeRows: [(String, [String])] = [
    ("Cafe\u{0301} Mu\u{0308}ller", ["cafe", "muller"]),  // accents as combining marks stay inside their word
    ("\u{FF22}\u{FF21}\u{FF2C}\u{FF21}", ["bala"]),  // full-width capitals
    ("BALA'S deck", ["bala", "deck"]),  // possessive in capitals
    ("10's", ["10", "s"]),  // only a letter may precede the 's
    ("Bala'sh", ["balash"]),  // the 's must end the word to be a possessive, otherwise it is a contraction
    ("Bala 's", ["bala", "s"]),  // and sit right after the letter
    ("'s", ["s"]),
    ("Cafe\u{0301}'s", ["cafe"]),  // a possessive may follow an accent written as a separate mark
    ("don\u{2019}t", ["dont"]),  // typographic apostrophe
    ("rock'n'roll", ["rocknroll"]),  // more than one apostrophe in a word
    ("O\u{2019}Brien\u{2019}s", ["obrien"]),  // a contraction, then a possessive
    ("'tis the dogs' toys", ["tis", "the", "dogs", "toys"]),  // an apostrophe at either end of a word is a separator
    ("rock'80s", ["rock", "80s"]),  // and so is one next to a digit
    ("\u{0301}Bala", ["bala"]),  // a lone combining mark is not a word
    ("Stra\u{00DF}e", ["strasse"]),  // case folding, not just lowercasing
]

private let osaRows: [(String, String, Int)] = [
    ("bala", "bala", 0),
    ("bala", "ball", 1),
    ("bala", "abla", 1),  // one transposition
    ("bala", "balaji", 2),
    ("", "abc", 3),
    ("kitten", "sitting", 3),
    ("ca", "abc", 3),  // optimal string alignment: "ca" -> "abc" is not 2 as in unrestricted Damerau-Levenshtein
]

private let nameKeyRows: [(String, String)] = [
    ("bala", "b*l*"),
    ("bhala", "b*l*"),
    ("balla", "b*l*"),
    ("ball", "b*l"),
    ("priyanka", "pr*nk*"),
    ("pryanka", "pr*nk*"),
    ("philip", "f*l*p"),
    ("chris", "kr*s"),
    ("thomas", "t*m*s"),
    ("william", "v*l*m"),
    ("shah", "s*"),
    ("42", "42"),
    ("", ""),
]

/// Beyond the table: every step of the key, in the order the spec lists them.
private let nameKeyStepRows: [(String, String)] = [
    ("BALA", "b*l*"),  // case is folded
    ("M\u{00FC}ller", "m*l*r"),  // so are accents, and doubled letters collapse
    ("quentin", "k*nt*n"),  // qu -> k
    ("jack", "j*k"),  // ck -> k
    ("alex", "al*ks"),  // x -> ks; the first letter is kept as it is, even a vowel
    ("zoe", "s*"),  // z -> s, then the trailing vowels merge into one *
    ("wyatt", "v*t"),  // w -> v, y -> i, collapsing the double t
    ("hari", "h*r*"),  // h stays when it is the first letter
    ("rahul", "r*l"),  // and goes everywhere else
    ("ghosh", "g*s"),  // gh -> g, sh -> s
    ("khan", "k*n"),  // kh -> k
    ("a1b", "a1b"),  // any digit: the word is its own key, as typed
    ("B2B", "B2B"),
    // "Бала" -> "бала": letters of other scripts are only lowercased, not touched by the ASCII rules
    ("\u{0411}\u{0430}\u{043B}\u{0430}", "\u{0431}\u{0430}\u{043B}\u{0430}"),
    // "बाला" keeps its vowel signs, so it does not collapse onto "बल"
    ("\u{092C}\u{093E}\u{0932}\u{093E}", "\u{092C}\u{093E}\u{0932}\u{093E}"),
    ("\u{092C}\u{0932}", "\u{092C}\u{0932}"),
]

private let budgetRows: [(Int, Int)] = [
    (0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 1), (6, 1), (8, 1), (9, 2), (10, 2), (20, 2),
]

/// Rows of the task table: term, heard word, and whether each sensitivity accepts the pair.
private let matchRows: [(String, String, Bool, Bool, Bool)] = [
    ("bala", "bala", true, true, true),
    ("bala", "ball", false, false, true),
    ("bala", "bhala", false, true, true),
    ("bala", "balla", false, true, true),
    ("bala", "bella", false, false, true),
    ("bala", "pala", false, false, true),
    ("bala", "b", false, false, false),
    ("standup", "standups", false, true, true),
    ("deploy", "display", false, false, false),
    ("krishnan", "krishna", false, true, true),
    ("al", "ali", false, false, false),
]

/// Beyond the table: the edges of each clause in the sensitivity rules.
private let matchEdgeRows: [(String, String, Bool, Bool, Bool)] = [
    // Balanced: a sound-alike may be off by 2 edits once the term has 6 or more letters, but only 1 below that.
    ("krishna", "krisshnaa", false, true, true),
    ("priya", "priyaaa", false, false, true),
    // Balanced sound-alikes need a term of 4 letters; Loose needs 3 for any non-identical match.
    ("rob", "rhob", false, false, true),
    ("abc", "abd", false, false, true),
    ("ba", "bah", false, false, false),
    ("ab", "ac", false, false, false),
    // Loose accepts any pair with the same NameKey, however far apart the spelling.
    ("bala", "bhalaa", false, false, true),
    // `len` counts characters, not bytes: "café" is 4 long (budget 0), although it takes 5 bytes.
    ("caf\u{00E9}", "caf\u{00E9}s", false, false, true),
    // Identical words match whatever their length.
    ("a", "a", true, true, true),
    ("42", "42", true, true, true),
]

/// Balanced must not take these for the name: an everyday word, or a word one vowel away from it. Term, heard.
/// ("logan", "login") is missing on purpose: "login" is not in SCOWL at any size, so see `loginIsAKnownGap`.
private let everydayWordRows: [(String, String)] = [
    ("mike", "make"), ("luke", "like"), ("theo", "the"), ("john", "join"), ("evan", "even"), ("nina", "nine"),
    ("beth", "both"), ("seth", "set"), ("tony", "tiny"), ("jane", "june"), ("mina", "mine"), ("shane", "share"),
    ("ethan", "than"), ("brian", "brain"), ("james", "names"), ("megan", "began"),
    ("casey", "case"), ("stacy", "stack"), ("paige", "page"), ("steven", "seven"), ("grant", "grand"),
]

/// ... while the ways a recognizer really mangles a name still count under Balanced. Term, heard.
private let misheardNameRows: [(String, String)] = [
    ("bala", "bhala"), ("bala", "balla"), ("bala", "baala"), ("john", "jhon"), ("sarah", "sara"),
    ("priyanka", "pryanka"), ("krishnan", "krishna"), ("standup", "standups"),
]

@Suite("MatchingPrimitives")
struct MatchingPrimitivesTests {
    // MARK: Tokens

    @Test(arguments: tokenRows)
    func tokens(input: String, expected: [String]) {
        #expect(TextNormalizer.tokens(input) == expected)
    }

    @Test(arguments: tokenEdgeRows)
    func tokenEdges(input: String, expected: [String]) {
        #expect(TextNormalizer.tokens(input) == expected)
    }

    @Test(arguments: tokenRows + tokenEdgeRows)
    func tokensAreTheNormalizedFormOfTokenize(input: String, expected: [String]) {
        #expect(TextNormalizer.tokenize(input).map(\.normalized) == expected)
    }

    @Test func normalizeTermSplitsLikeText() {
        #expect(TextNormalizer.normalizeTerm("  Stand-Up ") == ["stand", "up"])
        #expect(TextNormalizer.normalizeTerm("Bala") == ["bala"])
        #expect(TextNormalizer.normalizeTerm("Don't") == ["dont"])
    }

    @Test(arguments: ["", "   ", "!!!", "-", "\u{1F642}"])
    func termWithoutLettersOrDigitsHasNoTokens(term: String) {
        #expect(TextNormalizer.normalizeTerm(term).isEmpty)
    }

    @Test func tokenRangeMapsBackToTheOriginalText() {
        let text = "Hi Bala!"
        let tokens = TextNormalizer.tokenize(text)
        #expect(tokens.count == 2)
        #expect(String(text[tokens[1].range]) == "Bala")
        #expect(tokens[1].normalized == "bala")
    }

    @Test func tokenRangeIncludesTheApostropheOfAContraction() {
        let text = "I don't know"
        let tokens = TextNormalizer.tokenize(text)
        #expect(tokens.map(\.normalized) == ["i", "dont", "know"])
        #expect(tokens.map { String(text[$0.range]) } == ["I", "don't", "know"])
    }

    @Test func tokenRangeKeepsOriginalCasingAndLeavesOutThePossessive() {
        let text = "BALA's deck"
        let tokens = TextNormalizer.tokenize(text)
        #expect(tokens.map { String(text[$0.range]) } == ["BALA", "deck"])
    }

    @Test func tokenRangeIncludesCombiningMarks() {
        let text = "Cafe\u{0301} x"  // "Café x" with the accent as a separate mark
        let tokens = TextNormalizer.tokenize(text)
        #expect(tokens.map { String(text[$0.range]) } == ["Cafe\u{0301}", "x"])
    }

    @Test func tokenRangesAreOrderedAndDoNotOverlap() {
        let text = "  Hey -- Bala's  (stand-up) at 10:30, caf\u{00E9}!  "
        let ranges = TextNormalizer.tokenize(text).map(\.range)
        #expect(ranges.count == 8)  // Hey Bala stand up at 10 30 café
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            #expect(earlier.upperBound <= later.lowerBound)
        }
    }

    // MARK: Edit distance

    @Test(arguments: osaRows)
    func osa(a: String, b: String, expected: Int) {
        #expect(EditDistance.osa(a, b) == expected)
        #expect(EditDistance.osa(b, a) == expected, "the distance is symmetric")
    }

    @Test func osaCountsCharactersNotBytes() {
        #expect(EditDistance.osa("caf\u{00E9}", "cafe") == 1)  // one substitution, although "é" is two bytes
        #expect(EditDistance.osa("\u{1F642}", "\u{1F642}\u{1F642}") == 1)
        #expect(EditDistance.osa("caf\u{00E9}", "cafe\u{0301}") == 0)  // the same character, written two ways
    }

    // MARK: NameKey

    @Test(arguments: nameKeyRows)
    func nameKey(token: String, expected: String) {
        #expect(NameKey.key(token) == expected)
    }

    @Test(arguments: nameKeyStepRows)
    func nameKeySteps(token: String, expected: String) {
        #expect(NameKey.key(token) == expected)
    }

    // MARK: Sensitivity

    @Test(arguments: budgetRows)
    func budget(length: Int, expected: Int) {
        #expect(Sensitivity.budget(forLength: length) == expected)
    }

    @Test(arguments: matchRows)
    func matches(term: String, heard: String, exact: Bool, balanced: Bool, loose: Bool) {
        #expect(Sensitivity.exact.matches(term: term, heard: heard) == exact, "exact: \(term) vs \(heard)")
        #expect(Sensitivity.balanced.matches(term: term, heard: heard) == balanced, "balanced: \(term) vs \(heard)")
        #expect(Sensitivity.loose.matches(term: term, heard: heard) == loose, "loose: \(term) vs \(heard)")
    }

    @Test(arguments: matchEdgeRows)
    func matchEdges(term: String, heard: String, exact: Bool, balanced: Bool, loose: Bool) {
        #expect(Sensitivity.exact.matches(term: term, heard: heard) == exact, "exact: \(term) vs \(heard)")
        #expect(Sensitivity.balanced.matches(term: term, heard: heard) == balanced, "balanced: \(term) vs \(heard)")
        #expect(Sensitivity.loose.matches(term: term, heard: heard) == loose, "loose: \(term) vs \(heard)")
    }

    @Test(arguments: everydayWordRows)
    func balancedDoesNotTakeEverydayWordsForNames(term: String, heard: String) {
        #expect(!Sensitivity.balanced.matches(term: term, heard: heard), "balanced: \(term) vs \(heard)")
        #expect(!Sensitivity.exact.matches(term: term, heard: heard), "exact: \(term) vs \(heard)")
    }

    /// Logan is five letters, so one wrong vowel is inside Balanced's budget, and only the everyday-word list could
    /// refuse "login". SCOWL has no "login" in any of its lists. When the list gains it (a supplement, say), this
    /// test fails because the issue it expects is gone: move the pair into `everydayWordRows` then.
    @Test func loginIsAKnownGap() {
        withKnownIssue("SCOWL has no \"login\", so Balanced still takes it for Logan") {
            #expect(!Sensitivity.balanced.matches(term: "logan", heard: "login"))
        }
    }

    @Test(arguments: misheardNameRows)
    func balancedStillHearsMangledNames(term: String, heard: String) {
        #expect(Sensitivity.balanced.matches(term: term, heard: heard), "balanced: \(term) vs \(heard)")
        #expect(Sensitivity.loose.matches(term: term, heard: heard), "loose: \(term) vs \(heard)")
    }

    @Test(arguments: [("mike", "make"), ("shane", "share"), ("seth", "set"), ("theo", "the"), ("brian", "brain")])
    func looseIsExemptFromTheEverydayWordGuards(term: String, heard: String) {
        #expect(Sensitivity.loose.matches(term: term, heard: heard), "loose: \(term) vs \(heard)")
    }

    @Test(arguments: Sensitivity.allCases)
    func anEmptyNameKeyIsNeverASoundAlike(sensitivity: Sensitivity) {
        // Neither side has a letter, so the keys are both empty. That is not a phonetic match.
        #expect(sensitivity.matches(term: "!!!", heard: "???") == false)
    }
}
