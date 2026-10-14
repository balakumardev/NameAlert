import Foundation

/// One place where a rule's term was found in a text.
public struct MatchResult: Sendable, Equatable {
    public let ruleID: UUID
    /// The rule term that matched, as the user typed it, without the whitespace around it.
    public let term: String
    /// The matched words as they were written in the text, from the first to the last.
    public let matchedText: String
    /// The matched words with up to 8 words on either side, and `…` where the text goes on.
    public let context: String
    /// 1 for the first match of the rule in the text, 2 for the next, and so on. A match that was found in an
    /// alternative reading is always 1.
    public let ordinal: Int
    /// Whether the match comes from an alternative reading because the main text had none.
    public let fromAlternative: Bool
}

/// Decides which rules alert for each piece of transcript. It keeps a rule from alerting twice for the same
/// words, and from alerting again within its cooldown.
///
/// A rule matches when one of its terms is heard: word by word, or run together or split apart by the
/// recognizer ("Balakumar" and "Bala Kumar"). How close a heard word must be to the term depends on the
/// rule's sensitivity. See `Sensitivity.matches(term:heard:)`. Running words together is only tried when the heard
/// words all have 2 or more characters and the term has 7 or more, or has 5 or 6 and one of the heard words is not an
/// everyday word; and for spoken initials ("A. J."). So "Aman" is not heard in "a man" nor "Justin" in "just in",
/// while "Sriram" is heard in "sri ram" and "Sai Ram" in "sairam".
///
/// Where readings overlap, the closest one wins: every candidate is scored by its edit distance and they are
/// chosen lowest distance first, then earliest start, then most heard words, dropping any that overlaps one
/// already chosen. So in "this is bala kumar" the term "Balakumar" matches "bala kumar" (distance 0) and not
/// "is bala kumar" (distance 2).
public struct RuleEngine: Sendable {
    private var rules: [CompiledRule]
    private var lastFired: [UUID: Date] = [:]
    private var recentKeys: RecentKeys

    /// - Parameter recentKeyCapacity: How many reported matches are remembered, oldest forgotten first.
    public init(rules: [Rule], recentKeyCapacity: Int = 500) {
        self.rules = rules.map(CompiledRule.init)
        self.recentKeys = RecentKeys(capacity: recentKeyCapacity)
    }

    /// Replaces the rules. A rule that keeps its ID also keeps its cooldown and the matches it has already
    /// reported; what was remembered for rules that are gone is forgotten.
    public mutating func updateRules(_ rules: [Rule]) {
        self.rules = rules.map(CompiledRule.init)
        let ids = Set(rules.map(\.id))
        lastFired = lastFired.filter { ids.contains($0.key) }
        recentKeys.keepOnly(rulesIn: ids)
    }

    /// Forgets which matches have been reported, so that segment IDs can be used again. A speech engine numbers its
    /// segments from the start every time it is restarted, and a match in a new "s1" must not be taken for one in
    /// the old "s1". Cooldowns are kept: a rule that has just alerted stays quiet for the rest of its cooldown.
    /// Call this whenever a new pipeline starts.
    public mutating func forgetSegments() {
        recentKeys.removeAll()
    }

    /// Looks for the rules' terms in `update` and returns a `Hit` for each rule that should alert now.
    ///
    /// For each enabled rule the main text is searched first. Its matches are numbered 1, 2, ... in reading
    /// order. Only when the main text has no match are the alternative readings tried, in order; the first match
    /// found there is used and numbered 1.
    ///
    /// A match is identified by its segment, rule and number, and one that was seen before never alerts again.
    /// That is how a partial result that is later finalized alerts once, and a second mention in the same
    /// segment alerts as well. A new match is remembered even when its rule is still cooling down, so it does
    /// not alert later either. Otherwise it alerts when `cooldownSeconds` have passed since the rule last did.
    /// If `now` is earlier than that last alert (the clock was set back) the cooldown counts as over.
    public mutating func evaluate(
        _ update: TranscriptUpdate, source: AudioSourceKind, engine: EngineID, now: Date
    ) -> [Hit] {
        guard rules.contains(where: \.isActive) else { return [] }
        let primary = HeardText(update.text)
        var alternatives = AlternativeReadings(update.alternatives, besides: update.text)
        var hits: [Hit] = []
        for rule in rules where rule.isActive {
            var matches = rule.matches(in: primary, fromAlternative: false)
            if matches.isEmpty, let fromAlternative = alternatives.firstMatch(of: rule) {
                matches = [fromAlternative]
            }
            for match in matches {
                let key = "\(update.segmentID)|\(rule.id)|\(match.ordinal)"
                guard recentKeys.insert(key, forRule: rule.id) else { continue }
                if let last = lastFired[rule.id] {
                    // A clock that was set back makes `elapsed` negative. The rule must not stay silent until
                    // the clock catches up, so only a time between zero and the cooldown counts as cooling down.
                    let elapsed = now.timeIntervalSince(last)
                    if elapsed >= 0, elapsed < rule.cooldownSeconds { continue }
                }
                lastFired[rule.id] = now
                hits.append(
                    Hit(
                        ruleID: rule.id, ruleName: rule.name, term: match.term, matchedText: match.matchedText,
                        context: match.context, timestamp: now, source: source, engine: engine,
                        segmentID: update.segmentID))
            }
        }
        return hits
    }

    /// Every match of `rule` in `text`, in reading order and without overlap, numbered from 1. Where readings
    /// overlap the closest one is chosen (see `RuleEngine`). This is what the "type a sentence to test" fields
    /// use. It does not look at whether the rule is enabled.
    public static func matches(in text: String, rule: Rule) -> [MatchResult] {
        let rule = CompiledRule(rule)
        guard !rule.terms.isEmpty else { return [] }
        return rule.matches(in: HeardText(text), fromAlternative: false)
    }

    /// The terms of the enabled rules as typed, trimmed, without repeats (ignoring case) and at most 100, in
    /// rule order. A term with no letters or digits is left out: it can never be heard. Speech engines use the hints
    /// to favour these words.
    public static func hints(for rules: [Rule]) -> [String] {
        var seen = Set<String>()
        var hints: [String] = []
        for rule in rules where rule.isEnabled {
            for term in rule.terms {
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !TextNormalizer.normalizeTerm(trimmed).isEmpty, seen.insert(trimmed.lowercased()).inserted
                else { continue }
                hints.append(trimmed)
                if hints.count == maxHints { return hints }
            }
        }
        return hints
    }

    /// Whether `rule` can ever alert: it is turned on and has a word with a letter or a digit. A rule that cannot alert
    /// does not count against the rules Free alerts with (`ProPolicy`).
    public static func canFire(_ rule: Rule) -> Bool {
        CompiledRule(rule).isActive
    }
}

// MARK: - Limits

/// How many words of context are kept on each side of a match.
private let contextWords = 8
/// The most heard words that are joined to meet a term written as one word.
private let maxJoinedWords = 3
/// How many characters a term has to have, its words joined, to be met by heard words run together or split apart
/// whatever the heard words are.
private let minCompoundTermLength = 7
/// The least a term can have to be met that way at all, and then only when one of the heard words is not an everyday
/// word: "sri ram" is "Sriram", "just in" is not "Justin". Shorter terms would be found inside ordinary phrases:
/// "Aman" in "a man", "Isa" in "this is a test".
private let minCompoundTermLengthWithAnUncommonWord = 5
private let maxHints = 100
private let ellipsis = "\u{2026}"

// MARK: - Rules prepared for matching

/// A word of a term, with what the comparisons need worked out once.
private struct Word: Sendable {
    let text: String
    let length: Int
    private let foldedKey: String
    private let vowelKey: String

    init(_ text: String) {
        self.text = text
        length = text.count
        foldedKey = NameKey.key(text)
        vowelKey = NameKey.key(text, keepVowels: true)
    }

    /// The `NameKey` with its vowels folded, or the one that keeps them.
    func key(keepVowels: Bool) -> String {
        keepVowels ? vowelKey : foldedKey
    }
}

private struct CompiledTerm: Sendable {
    /// The term as the user typed it, without the whitespace around it.
    let typed: String
    let words: [Word]
    /// All the words run together.
    let joined: Word
}

private struct CompiledRule: Sendable {
    let id: UUID
    let name: String
    let sensitivity: Sensitivity
    let isEnabled: Bool
    let cooldownSeconds: Double
    /// Without terms that have no letters or digits, and without repeats.
    let terms: [CompiledTerm]

    init(_ rule: Rule) {
        id = rule.id
        name = rule.name
        sensitivity = rule.sensitivity
        isEnabled = rule.isEnabled
        cooldownSeconds = rule.cooldownSeconds
        var seen = Set<[String]>()
        terms = rule.terms.compactMap { typed in
            let words = TextNormalizer.normalizeTerm(typed)
            guard !words.isEmpty, seen.insert(words).inserted else { return nil }
            let compiled = words.map(Word.init)
            return CompiledTerm(
                typed: typed.trimmingCharacters(in: .whitespacesAndNewlines), words: compiled,
                joined: compiled.count == 1 ? compiled[0] : Word(words.joined()))
        }
    }

    /// Whether the rule can ever fire.
    var isActive: Bool { isEnabled && !terms.isEmpty }
}

// MARK: - Heard text

/// A text split into words once, and the runs of one to three words joined together that a term written as
/// one word is compared with. Shared by all rules. Name keys are worked out when a comparison first needs them.
private final class HeardText {
    let text: String
    let tokens: [Token]
    // The tables are indexed by `(count - 1) * tokens.count + start`: `count` words from word `start`.
    private let joinedTexts: [String]
    private let joinedLengths: [Int]
    private var joinedKeys: [String?]
    private var joinedVowelKeys: [String?]

    init(_ text: String) {
        self.text = text
        let tokens = TextNormalizer.tokenize(text)
        self.tokens = tokens
        let n = tokens.count
        var texts = [String](repeating: "", count: n * maxJoinedWords)
        var lengths = [Int](repeating: 0, count: n * maxJoinedWords)
        for start in 0..<n {
            var joined = ""
            for count in 1...maxJoinedWords where start + count <= n {
                joined += tokens[start + count - 1].normalized
                texts[(count - 1) * n + start] = joined
                lengths[(count - 1) * n + start] = joined.count
            }
        }
        joinedTexts = texts
        joinedLengths = lengths
        joinedKeys = [String?](repeating: nil, count: n * maxJoinedWords)
        joinedVowelKeys = joinedKeys
    }

    func joined(_ count: Int, at start: Int) -> String {
        joinedTexts[(count - 1) * tokens.count + start]
    }

    func length(_ count: Int, at start: Int) -> Int {
        joinedLengths[(count - 1) * tokens.count + start]
    }

    /// Whether the `count` words from word `start` may be compared run together with a term of `termLength`
    /// characters (its words joined). That is so when every heard word is a single character, as when initials are
    /// spoken ("A. J."). Otherwise every heard word needs two characters or more, and the term must either have 7 or
    /// more, or have 5 or 6 while at least one of the heard words is not an everyday word.
    func mayBeRunTogether(_ count: Int, at start: Int, forTermOfLength termLength: Int) -> Bool {
        let words = start..<(start + count)
        var allSingle = true
        var allLong = true
        for position in words {
            let wordLength = length(1, at: position)
            if wordLength != 1 { allSingle = false }
            if wordLength < 2 { allLong = false }
        }
        if allSingle { return true }
        guard allLong, termLength >= minCompoundTermLengthWithAnUncommonWord else { return false }
        if termLength >= minCompoundTermLength { return true }
        return words.contains { !CommonWords.contains(tokens[$0].normalized) }
    }

    /// The `NameKey` of the run, with its vowels folded or kept. Worked out the first time it is asked for.
    func key(_ count: Int, at start: Int, keepVowels: Bool) -> String {
        let slot = (count - 1) * tokens.count + start
        if let key = keepVowels ? joinedVowelKeys[slot] : joinedKeys[slot] { return key }
        let key = NameKey.key(joinedTexts[slot], keepVowels: keepVowels)
        if keepVowels {
            joinedVowelKeys[slot] = key
        } else {
            joinedKeys[slot] = key
        }
        return key
    }

    /// The `count` words from word `start`, as written.
    func matchedText(start: Int, count: Int) -> String {
        String(text[tokens[start].range.lowerBound..<tokens[start + count - 1].range.upperBound])
    }

    /// The `count` words from word `start` with up to `contextWords` words on each side. The slice starts where
    /// the first word starts and ends where the last one ends, so punctuation outside them is left out.
    func context(start: Int, count: Int) -> String {
        let first = max(0, start - contextWords)
        let last = min(tokens.count - 1, start + count - 1 + contextWords)
        var context = String(text[tokens[first].range.lowerBound..<tokens[last].range.upperBound])
        if first > 0 { context = ellipsis + context }
        if last < tokens.count - 1 { context += ellipsis }
        return context
    }
}

/// One way a rule's term matches the heard words: `count` of them, from word `start`.
private struct Candidate {
    /// Which of the rule's terms matched.
    let term: Int
    let start: Int
    let count: Int
    /// The edit distance of the reading: summed over the words for a word-by-word match, the distance between
    /// the joined strings for a run-together one. It is counted even when a sound-alike made the words match.
    let score: Int
    /// Where the candidate was found among the others, so that exact ties are settled the same way every time.
    let order: Int
}

// MARK: - Matching

extension CompiledTerm {
    /// Adds every way the term matches from heard word `start`: word by word, and run together against one, two
    /// or three heard words joined.
    fileprivate func appendCandidates(
        term: Int, at start: Int, in heard: HeardText, _ sensitivity: Sensitivity, to candidates: inout [Candidate]
    ) {
        let available = heard.tokens.count - start
        if words.count <= available {
            var score = 0
            var everyWordMatches = true
            for (offset, word) in words.enumerated() {
                let position = start + offset
                let heardWord = heard.joined(1, at: position)
                let matches = sensitivity.matches(
                    term: word.text, termLength: word.length, termKey: { word.key(keepVowels: $0) },
                    heard: heardWord, heardLength: heard.length(1, at: position),
                    heardKey: { heard.key(1, at: position, keepVowels: $0) })
                guard matches else {
                    everyWordMatches = false
                    break
                }
                score += EditDistance.osa(word.text, heardWord)
            }
            if everyWordMatches {
                let order = candidates.count
                candidates.append(Candidate(term: term, start: start, count: words.count, score: score, order: order))
            }
        }
        for count in 1...maxJoinedWords where count <= available {
            // One heard word against a one-word term is the comparison made above.
            if count == 1 && words.count == 1 { continue }
            guard heard.mayBeRunTogether(count, at: start, forTermOfLength: joined.length) else { continue }
            let heardRun = heard.joined(count, at: start)
            let matches = sensitivity.matches(
                term: joined.text, termLength: joined.length, termKey: { joined.key(keepVowels: $0) },
                heard: heardRun, heardLength: heard.length(count, at: start),
                heardKey: { heard.key(count, at: start, keepVowels: $0) })
            if matches {
                let order = candidates.count
                let score = EditDistance.osa(joined.text, heardRun)
                candidates.append(Candidate(term: term, start: start, count: count, score: score, order: order))
            }
        }
    }
}

extension CompiledRule {
    /// The matches of the rule in `heard`, in reading order.
    ///
    /// Every candidate is scored by its edit distance and they are chosen greedily: lowest distance first, then
    /// the earliest start, then the one covering more heard words (then the earlier term). A candidate that
    /// overlaps one already chosen is dropped.
    fileprivate func select(in heard: HeardText) -> [Candidate] {
        var candidates: [Candidate] = []
        for (index, term) in terms.enumerated() {
            for start in heard.tokens.indices {
                term.appendCandidates(term: index, at: start, in: heard, sensitivity, to: &candidates)
            }
        }
        guard candidates.count > 1 else { return candidates }
        candidates.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.start != b.start { return a.start < b.start }
            if a.count != b.count { return a.count > b.count }
            return a.order < b.order
        }
        var taken = [Bool](repeating: false, count: heard.tokens.count)
        var chosen: [Candidate] = []
        for candidate in candidates {
            let words = candidate.start..<(candidate.start + candidate.count)
            if taken[words].contains(true) { continue }
            for position in words { taken[position] = true }
            chosen.append(candidate)
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Every match in `heard`, numbered from 1 in reading order.
    fileprivate func matches(in heard: HeardText, fromAlternative: Bool) -> [MatchResult] {
        select(in: heard).enumerated().map { index, candidate in
            result(for: candidate, ordinal: index + 1, in: heard, fromAlternative: fromAlternative)
        }
    }

    /// The first match in `heard`, numbered 1.
    fileprivate func firstMatch(in heard: HeardText, fromAlternative: Bool) -> MatchResult? {
        select(in: heard).first.map { result(for: $0, ordinal: 1, in: heard, fromAlternative: fromAlternative) }
    }

    private func result(
        for candidate: Candidate, ordinal: Int, in heard: HeardText, fromAlternative: Bool
    ) -> MatchResult {
        MatchResult(
            ruleID: id, term: terms[candidate.term].typed,
            matchedText: heard.matchedText(start: candidate.start, count: candidate.count),
            context: heard.context(start: candidate.start, count: candidate.count),
            ordinal: ordinal, fromAlternative: fromAlternative)
    }
}

/// The alternative readings of an update. Each is split into words the first time a rule needs it.
private struct AlternativeReadings {
    private let texts: [String]
    private var heard: [HeardText?]

    /// Readings equal to the main text, or to an earlier one, are left out: they cannot match differently.
    init(_ texts: [String], besides primary: String) {
        var seen: Set<String> = [primary]
        let distinct = texts.filter { seen.insert($0).inserted }
        self.texts = distinct
        heard = [HeardText?](repeating: nil, count: distinct.count)
    }

    /// The first match of `rule` in the first reading that has one.
    mutating func firstMatch(of rule: CompiledRule) -> MatchResult? {
        for index in texts.indices {
            let reading = heard[index] ?? HeardText(texts[index])
            heard[index] = reading
            if let match = rule.firstMatch(in: reading, fromAlternative: true) { return match }
        }
        return nil
    }
}

// MARK: - Remembered matches

/// The keys of the matches already reported, newest last. Beyond `capacity` the oldest are forgotten.
private struct RecentKeys: Sendable {
    private struct Entry: Sendable {
        let ruleID: UUID
        let key: String
    }

    private let capacity: Int
    private var entries: [Entry] = []
    private var members: Set<String> = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Remembers `key`. Returns `false`, and changes nothing, when it is already remembered.
    mutating func insert(_ key: String, forRule ruleID: UUID) -> Bool {
        if members.contains(key) { return false }
        guard capacity > 0 else { return true }
        members.insert(key)
        entries.append(Entry(ruleID: ruleID, key: key))
        if entries.count > capacity { members.remove(entries.removeFirst().key) }
        return true
    }

    /// Forgets every key.
    mutating func removeAll() {
        entries.removeAll()
        members.removeAll()
    }

    /// Forgets the keys of every rule that is not in `ids`.
    mutating func keepOnly(rulesIn ids: Set<UUID>) {
        entries.removeAll { !ids.contains($0.ruleID) }
        members = Set(entries.map(\.key))
    }
}
