/// How far apart two words are.
public enum EditDistance {
    /// Damerau-Levenshtein distance in its "optimal string alignment" form: the fewest single-character
    /// insertions, deletions, substitutions and swaps of two neighbouring characters that turn `a` into `b`,
    /// where no part of the text is edited twice. So "ca" to "abc" is 3 here, not 2.
    ///
    /// Compares `Character`s, so an accented letter or an emoji counts as one.
    public static func osa(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        // Plain ASCII compares as bytes, which is much cheaper than comparing Characters. A carriage return
        // is left out because "\r\n" is one Character but two bytes.
        if isPlainASCII(a), isPlainASCII(b) { return distance(Array(a.utf8), Array(b.utf8)) }
        return distance(Array(a), Array(b))
    }

    private static func isPlainASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 && $0 != 0x0D }
    }

    private static func distance<Element: Equatable>(_ s: [Element], _ t: [Element]) -> Int {
        let n = s.count, m = t.count
        if n == 0 { return m }
        if m == 0 { return n }
        // Row i of the table, plus the two rows before it (the swap looks two rows back).
        var beforePrevious = [Int](repeating: 0, count: m + 1)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var best = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    best = min(best, beforePrevious[j - 2] + 1)
                }
                current[j] = best
            }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[m]
    }
}
