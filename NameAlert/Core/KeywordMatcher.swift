import Foundation

/// Maintains a rolling buffer of transcript text and emits `Hit`s when a configured
/// keyword matches (exact or within Damerau-Levenshtein `tolerance` edits).
/// Per-keyword `cooldownSeconds` suppresses duplicate alerts.
struct KeywordMatcher: Sendable {
    static let maxBufferChars = 500

    var keywords: [String]
    var tolerance: Int
    var cooldownSeconds: TimeInterval

    private(set) var rollingWindow: String = ""
    private var lastFiredAt: [String: Date] = [:]

    init(keywords: [String], tolerance: Int = 1, cooldownSeconds: TimeInterval = 5) {
        self.keywords = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.tolerance = max(0, tolerance)
        self.cooldownSeconds = max(0, cooldownSeconds)
    }

    /// Replace the entire rolling window. Used when the transcriber emits cumulative
    /// volatile transcripts (the result text is the running session text, not a delta).
    mutating func setWindow(_ text: String) {
        rollingWindow = String(text.suffix(Self.maxBufferChars))
    }

    /// Append delta text and trim to cap.
    mutating func append(_ delta: String) {
        rollingWindow.append(delta)
        if rollingWindow.count > Self.maxBufferChars {
            rollingWindow = String(rollingWindow.suffix(Self.maxBufferChars))
        }
    }

    /// Tokenize the current window and return any new keyword hits not in cooldown.
    mutating func evaluate(now: Date = Date()) -> [Hit] {
        guard !keywords.isEmpty else { return [] }
        let tokens = Self.tokenize(rollingWindow)
        var hits: [Hit] = []
        for token in tokens {
            for keyword in keywords {
                let distance = Self.damerauLevenshtein(token, keyword)
                if distance <= tolerance {
                    if let last = lastFiredAt[keyword],
                       now.timeIntervalSince(last) < cooldownSeconds {
                        continue
                    }
                    lastFiredAt[keyword] = now
                    hits.append(Hit(keyword: keyword, matchedText: token,
                                    timestamp: now, distance: distance))
                    break
                }
            }
        }
        return hits
    }

    /// Convenience: append + evaluate in one call.
    mutating func ingest(delta: String, now: Date = Date()) -> [Hit] {
        append(delta)
        return evaluate(now: now)
    }

    /// Convenience for cumulative transcripts.
    mutating func ingest(cumulative text: String, now: Date = Date()) -> [Hit] {
        setWindow(text)
        return evaluate(now: now)
    }

    // MARK: - Helpers

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Damerau-Levenshtein distance with adjacent-transposition cost 1.
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        let n = s.count, m = t.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prevPrev = Array(repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
                if i > 1, j > 1,
                   s[i - 1] == t[j - 2],
                   s[i - 2] == t[j - 1] {
                    curr[j] = min(curr[j], prevPrev[j - 2] + 1)
                }
            }
            prevPrev = prev
            prev = curr
            curr = Array(repeating: 0, count: m + 1)
        }
        return prev[m]
    }
}
