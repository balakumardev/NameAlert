import XCTest
@testable import NameAlert

final class KeywordMatcherTests: XCTestCase {
    func testExactMatch() {
        var m = KeywordMatcher(keywords: ["bala"], tolerance: 0, cooldownSeconds: 0)
        let hits = m.ingest(cumulative: "hey bala can you join")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.keyword, "bala")
        XCTAssertEqual(hits.first?.distance, 0)
    }

    func testFuzzyOneEdit() {
        var m = KeywordMatcher(keywords: ["bala"], tolerance: 1, cooldownSeconds: 0)
        let hits = m.ingest(cumulative: "i think bola is here")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.distance, 1)
    }

    func testFuzzyToleranceRespected() {
        var m = KeywordMatcher(keywords: ["bala"], tolerance: 0, cooldownSeconds: 0)
        let hits = m.ingest(cumulative: "bola was here")
        XCTAssertEqual(hits.count, 0, "tolerance 0 should reject 1-edit matches")
    }

    func testTransposition() {
        var m = KeywordMatcher(keywords: ["bala"], tolerance: 1, cooldownSeconds: 0)
        let hits = m.ingest(cumulative: "lets ask balla wait i mean baal")
        XCTAssertGreaterThan(hits.count, 0, "transposition or single edit should match")
    }

    func testCooldownSuppressesDuplicate() {
        var m = KeywordMatcher(keywords: ["bala"], tolerance: 0, cooldownSeconds: 5)
        let now = Date()
        let first = m.ingest(cumulative: "bala", now: now)
        XCTAssertEqual(first.count, 1)
        let second = m.ingest(cumulative: "bala", now: now.addingTimeInterval(1))
        XCTAssertEqual(second.count, 0, "should be suppressed by cooldown")
        let third = m.ingest(cumulative: "bala", now: now.addingTimeInterval(6))
        XCTAssertEqual(third.count, 1, "should fire again after cooldown")
    }

    func testRollingWindowTrimming() {
        var m = KeywordMatcher(keywords: ["zzz"], tolerance: 0, cooldownSeconds: 0)
        let filler = String(repeating: "a", count: KeywordMatcher.maxBufferChars + 100)
        m.append(filler)
        XCTAssertLessThanOrEqual(m.rollingWindow.count, KeywordMatcher.maxBufferChars)
    }

    func testMultipleKeywords() {
        var m = KeywordMatcher(keywords: ["bala", "kumara"], tolerance: 0, cooldownSeconds: 0)
        let hits = m.ingest(cumulative: "hi bala and also kumara")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.keyword)), ["bala", "kumara"])
    }

    func testEmptyKeywordsNoHits() {
        var m = KeywordMatcher(keywords: [], tolerance: 1, cooldownSeconds: 0)
        XCTAssertEqual(m.ingest(cumulative: "anything goes").count, 0)
    }

    func testDamerauLevenshteinKnownDistances() {
        XCTAssertEqual(KeywordMatcher.damerauLevenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(KeywordMatcher.damerauLevenshtein("ca", "ac"), 1, "transposition cost 1")
        XCTAssertEqual(KeywordMatcher.damerauLevenshtein("bala", "bala"), 0)
        XCTAssertEqual(KeywordMatcher.damerauLevenshtein("", "abc"), 3)
    }

    func testTokenization() {
        let tokens = KeywordMatcher.tokenize("Hello, World! Bala-Kumara_42")
        XCTAssertEqual(tokens, ["hello", "world", "bala", "kumara", "42"])
    }
}
