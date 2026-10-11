extension Sensitivity {
    /// How many edits a word of `length` characters may be off by and still count as the same word:
    /// none up to 4 characters, one for 5 to 8, two for 9 and more.
    public static func budget(forLength length: Int) -> Int {
        switch length {
        case ...4: 0
        case 5...8: 1
        default: 2
        }
    }

    /// Whether the heard word counts as the term at this sensitivity. Both are already normalized, and `len`
    /// below is the number of characters in `term`.
    ///
    /// - `exact`: the words are equal.
    /// - `balanced`: equal; or within `budget(len)` edits; or, for `len >= 4`, a sound-alike (same `NameKey`)
    ///   within 1 edit (`len` up to 5) or 2 edits (longer).
    /// - `loose`: equal; or, for `len >= 3`, within `budget(len) + 1` edits or a sound-alike at any distance.
    public func matches(term: String, heard: String) -> Bool {
        matches(
            term: term, termLength: term.count, termKey: { NameKey.key(term) },
            heard: heard, heardLength: heard.count, heardKey: { NameKey.key(heard) })
    }

    /// The comparison itself, for callers that already know the lengths and can hand out `NameKey`s from a cache.
    /// The keys are only asked for when the decision needs them.
    func matches(
        term: String, termLength: Int, termKey: () -> String,
        heard: String, heardLength: Int, heardKey: () -> String
    ) -> Bool {
        if term == heard { return true }
        // Two words whose lengths differ by more than the edits allowed cannot be that close.
        let lengthGap = abs(heardLength - termLength)
        switch self {
        case .exact:
            return false
        case .balanced:
            let budget = Self.budget(forLength: termLength)
            let soundAlikeEdits = termLength >= 4 ? (termLength <= 5 ? 1 : 2) : 0
            guard lengthGap <= max(budget, soundAlikeEdits), max(budget, soundAlikeEdits) > 0 else { return false }
            let distance = EditDistance.osa(term, heard)
            if distance <= budget { return true }
            return termLength >= 4 && distance <= soundAlikeEdits && Self.soundAlike(termKey(), heardKey())
        case .loose:
            guard termLength >= 3 else { return false }
            let edits = Self.budget(forLength: termLength) + 1
            if lengthGap <= edits, EditDistance.osa(term, heard) <= edits { return true }
            return Self.soundAlike(termKey(), heardKey())
        }
    }

    /// Equal keys, but an empty key (no letters at all) says nothing about how a word sounds.
    private static func soundAlike(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && a == b
    }
}
