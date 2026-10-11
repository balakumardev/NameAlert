import Foundation
import NameAlertCore  // not @testable: these tests see only what other modules see
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// `seconds` after `t0`.
private func after(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private let bala = Rule(name: "My name", terms: ["Bala", "Balakumar"])

private func segment(
    _ id: String, _ text: String, alternatives: [String] = [], isFinal: Bool = false
) -> TranscriptUpdate {
    TranscriptUpdate(segmentID: id, text: text, alternatives: alternatives, isFinal: isFinal)
}

extension RuleEngine {
    fileprivate mutating func hear(_ update: TranscriptUpdate, at time: Date) -> [Hit] {
        evaluate(update, source: .systemAudio, engine: .appleSFSpeech, now: time)
    }
}

@Suite("RuleEngine")
struct RuleEngineTests {
    // MARK: Hits and dedupe

    @Test func singleMention() throws {
        var engine = RuleEngine(rules: [bala])
        let hits = engine.hear(segment("s1", "Hey Bala, can you share"), at: t0)
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.matchedText == "Bala")
        #expect(hit.context == "Hey Bala, can you share")
        #expect(hit.term == "Bala")
    }

    @Test func hitRecordsWhatWasHeardAndWhere() throws {
        var engine = RuleEngine(rules: [bala])
        let update = segment("seg-7", "Hey Bala")
        let hits = engine.evaluate(update, source: .microphone, engine: .whisperLight, now: after(3))
        let hit = try #require(hits.first)
        #expect(hit.ruleID == bala.id)
        #expect(hit.ruleName == "My name")
        #expect(hit.timestamp == after(3))
        #expect(hit.source == .microphone)
        #expect(hit.engine == .whisperLight)
        #expect(hit.segmentID == "seg-7")
    }

    @Test func volatileThenFinalFiresOnce() {
        var engine = RuleEngine(rules: [bala])
        let volatile = engine.hear(segment("s1", "Hey Bala can"), at: t0)
        let final = engine.hear(segment("s1", "Hey Bala can you share the deck", isFinal: true), at: after(1))
        #expect(volatile.count == 1)
        #expect(final.isEmpty)
    }

    @Test func secondMentionSameSegment() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Bala said hi"), at: t0)
        let second = engine.hear(segment("s1", "Bala said hi and later Bala again"), at: after(11))
        #expect(first.count == 1)
        #expect(second.count == 1)
    }

    @Test func secondMentionInsideCooldownNeverFiresLater() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Bala and Bala"), at: t0)
        let later = engine.hear(segment("s1", "Bala and Bala"), at: after(20))
        #expect(first.count == 1)
        #expect(later.isEmpty)
    }

    @Test func newSegmentRespectsCooldown() {
        var engine = RuleEngine(rules: [bala])
        let hits =
            [
                engine.hear(segment("s1", "Bala"), at: t0),
                engine.hear(segment("s2", "Bala"), at: after(5)),
                engine.hear(segment("s3", "Bala"), at: after(10)),
            ]
        #expect(hits.map(\.count) == [1, 0, 1])
    }

    @Test func cooldownEndsExactlyAtTheRulesCooldown() {
        var engine = RuleEngine(rules: [Rule(name: "Slow", terms: ["Bala"], cooldownSeconds: 30)])
        let hits =
            [
                engine.hear(segment("s1", "Bala"), at: t0),
                engine.hear(segment("s2", "Bala"), at: after(29.9)),
                engine.hear(segment("s3", "Bala"), at: after(30)),
            ]
        #expect(hits.map(\.count) == [1, 0, 1])
    }

    @Test func clockSteppingBackDoesNotSilenceRule() {
        var engine = RuleEngine(rules: [bala])
        let hits =
            [
                engine.hear(segment("s1", "Bala"), at: after(100)),
                engine.hear(segment("s2", "Bala"), at: after(50)),  // the clock was set back: the cooldown is over
                engine.hear(segment("s3", "Bala"), at: after(55)),  // and it counts from the new time
                engine.hear(segment("s4", "Bala"), at: after(60)),
            ]
        #expect(hits.map(\.count) == [1, 1, 0, 1])
    }

    @Test func eachRuleHasItsOwnCooldown() {
        let quick = Rule(name: "Quick", terms: ["Bala"], cooldownSeconds: 2)
        let slow = Rule(name: "Slow", terms: ["Bala"], cooldownSeconds: 60)
        var engine = RuleEngine(rules: [quick, slow])
        let first = engine.hear(segment("s1", "Bala"), at: t0)
        let second = engine.hear(segment("s2", "Bala"), at: after(5))
        #expect(first.map(\.ruleID) == [quick.id, slow.id])
        #expect(second.map(\.ruleID) == [quick.id])
    }

    @Test func recentKeysAreForgottenOldestFirst() {
        let fast = Rule(name: "Fast", terms: ["Bala"], cooldownSeconds: 2)
        var engine = RuleEngine(rules: [fast], recentKeyCapacity: 2)
        let hits =
            [
                engine.hear(segment("s1", "Bala"), at: t0),  // remembers: s1
                engine.hear(segment("s2", "Bala"), at: after(3)),  // s1 s2
                engine.hear(segment("s3", "Bala"), at: after(6)),  // s2 s3: s1 is forgotten
                engine.hear(segment("s1", "Bala"), at: after(9)),  // new again; s3 s1
                engine.hear(segment("s3", "Bala"), at: after(12)),  // still remembered
            ]
        #expect(hits.map(\.count) == [1, 1, 1, 1, 0])
    }

    // MARK: Rules

    @Test func disabledRuleSilent() {
        var disabled = bala
        disabled.isEnabled = false
        var engine = RuleEngine(rules: [disabled])
        #expect(engine.hear(segment("s1", "Bala"), at: t0).isEmpty)
    }

    @Test func twoRulesBothFire() {
        let standup = Rule(name: "Standup", terms: ["stand up"])
        var engine = RuleEngine(rules: [bala, standup])
        let hits = engine.hear(segment("s1", "Bala, stand up is now"), at: t0)
        #expect(hits.map(\.ruleID) == [bala.id, standup.id])
        #expect(hits.map(\.matchedText) == ["Bala", "stand up"])
    }

    @Test func degenerateTermsIgnored() {
        let junk = Rule(name: "Junk", terms: ["", "   ", "!!!"])
        var engine = RuleEngine(rules: [junk])
        #expect(engine.hear(segment("s1", "any text"), at: t0).isEmpty)
        #expect(engine.hear(segment("s2", "!!! ... ???", alternatives: ["", "bala"]), at: after(100)).isEmpty)
        #expect(RuleEngine.matches(in: "any text", rule: junk).isEmpty)
        #expect(engine.hear(segment("s3", ""), at: after(200)).isEmpty)
    }

    @Test func contractionsDoNotMatchShortNames() throws {
        // "don't" is the one word "dont", so a user named Don is not alerted by it.
        var engine = RuleEngine(rules: [Rule(name: "Don", terms: ["Don"])])
        let hits = engine.hear(segment("s1", "I don't know, Don"), at: t0)
        #expect(hits.count == 1)
        #expect(try #require(hits.first).matchedText == "Don")
    }

    @Test func sensitivityComesFromTheRule() {
        func found(_ heard: String, _ sensitivity: Sensitivity) -> Bool {
            let rule = Rule(name: "N", terms: ["Bala"], sensitivity: sensitivity)
            return !RuleEngine.matches(in: heard, rule: rule).isEmpty
        }
        #expect(found("Bala", .exact))
        #expect(!found("Bhala", .exact))
        #expect(found("Bhala", .balanced))
        #expect(!found("Ball", .balanced))
        #expect(found("Ball", .loose))
        #expect(found("Bella", .loose))
        #expect(!found("Bub", .loose))
    }

    @Test func duplicateTermsReportTheFirstSpelling() throws {
        let rule = Rule(name: "N", terms: ["Bala", "bala", "BALA"])
        let results = RuleEngine.matches(in: "hey bala", rule: rule)
        #expect(results.count == 1)
        #expect(try #require(results.first).term == "Bala")
    }

    @Test func updateRulesKeepsCooldown() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Bala"), at: t0)
        var changed = bala
        changed.channels = [.sound]
        engine.updateRules([changed])
        let second = engine.hear(segment("s2", "Bala"), at: after(5))
        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    @Test func updateRulesDropsTheStateOfRemovedRules() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Bala"), at: t0)
        engine.updateRules([])
        engine.updateRules([bala])
        let again = engine.hear(segment("s1", "Bala"), at: after(1))  // neither cooldown nor key is remembered
        #expect(first.count == 1)
        #expect(again.count == 1)
    }

    @Test func updateRulesAppliesNewTermsAndSettings() {
        var engine = RuleEngine(rules: [bala])
        #expect(engine.hear(segment("s1", "Priya"), at: t0).isEmpty)
        var renamed = bala
        renamed.terms = ["Priya"]
        engine.updateRules([renamed])
        #expect(engine.hear(segment("s2", "Priya"), at: after(1)).count == 1)
        renamed.isEnabled = false
        engine.updateRules([renamed])
        #expect(engine.hear(segment("s3", "Priya"), at: after(100)).isEmpty)
    }

    // MARK: Alternatives

    @Test func alternativeMatch() throws {
        var engine = RuleEngine(rules: [bala])
        let hits = engine.hear(segment("s1", "Hey Bella", alternatives: ["Hey Bala"]), at: t0)
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.matchedText == "Bala")
        #expect(hit.context == "Hey Bala")
    }

    @Test func alternativeThenFinalFiresOnce() {
        var engine = RuleEngine(rules: [bala])
        let early = engine.hear(segment("s1", "Hey Bella", alternatives: ["Hey Bala"]), at: t0)
        let final = engine.hear(segment("s1", "Hey Bala", isFinal: true), at: after(1))
        #expect(early.count == 1)
        #expect(final.isEmpty)
    }

    @Test func alternativesAreOnlyConsultedWhenTheTextHasNoMatch() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Hey Bala", alternatives: ["Hey Bala Bala"]), at: t0)
        // Had the alternative been read, its second mention would already be remembered and stay silent now.
        let later = engine.hear(segment("s1", "Hey Bala Bala"), at: after(20))
        #expect(first.count == 1)
        #expect(later.count == 1)
    }

    @Test func alternativesAreSearchedInOrder() throws {
        var engine = RuleEngine(rules: [bala])
        let update = segment("s1", "Nothing here", alternatives: ["Hey Bella", "Hello Balakumar", "Hey Bala"])
        let hit = try #require(engine.hear(update, at: t0).first)
        #expect(hit.matchedText == "Balakumar")
        #expect(hit.term == "Balakumar")
    }

    @Test func onlyTheFirstMatchOfAnAlternativeIsUsed() {
        var engine = RuleEngine(rules: [bala])
        let first = engine.hear(segment("s1", "Nothing", alternatives: ["Bala and Bala"]), at: t0)
        // The alternative used up ordinal 1 only, so the second mention is still new when the text catches up.
        let later = engine.hear(segment("s1", "Bala and Bala"), at: after(20))
        #expect(first.count == 1)
        #expect(later.count == 1)
    }

    @Test func eachRuleFallsBackToAlternativesOnItsOwn() {
        let standup = Rule(name: "Standup", terms: ["stand up"])
        var engine = RuleEngine(rules: [bala, standup])
        let hits = engine.hear(segment("s1", "Bala is here", alternatives: ["stand up is here"]), at: t0)
        #expect(hits.map(\.ruleID) == [bala.id, standup.id])
        #expect(hits.map(\.matchedText) == ["Bala", "stand up"])
    }

    // MARK: Compounds

    @Test func compoundJoin() throws {
        let full = Rule(name: "Full name", terms: ["Balakumar"])
        var engine = RuleEngine(rules: [full])
        let hits = engine.hear(segment("s1", "this is bala kumar speaking"), at: t0)
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.matchedText == "bala kumar")
        #expect(hit.term == "Balakumar")
    }

    @Test func compoundSplit() throws {
        let split = Rule(name: "Split", terms: ["Bala Kumar"])
        var engine = RuleEngine(rules: [split])
        let hits = engine.hear(segment("s1", "hello balakumar"), at: t0)
        #expect(hits.count == 1)
        #expect(try #require(hits.first).matchedText == "balakumar")
    }

    @Test func distanceAwareSelection() throws {
        let full = Rule(name: "Full name", terms: ["Balakumar"])
        var engine = RuleEngine(rules: [full])
        let hits = engine.hear(segment("s1", "ba la kumar is here"), at: t0)
        #expect(hits.count == 1)
        #expect(try #require(hits.first).matchedText == "ba la kumar")
    }

    @Test func compoundPrefersTheSpanThatCoversMoreWords() throws {
        // "Bala" alone matches at the same word, but "Balakumar" joined covers both heard words.
        var engine = RuleEngine(rules: [bala])
        let hits = engine.hear(segment("s1", "this is bala kumar speaking"), at: t0)
        #expect(hits.count == 1)
        let hit = try #require(hits.first)
        #expect(hit.matchedText == "bala kumar")
        #expect(hit.term == "Balakumar")
    }

    @Test func compoundCoversUpToThreeHeardWords() {
        let rule = Rule(name: "N", terms: ["Balakumar"], sensitivity: .exact)
        #expect(RuleEngine.matches(in: "so ba la kumar here", rule: rule).map(\.matchedText) == ["ba la kumar"])
        #expect(RuleEngine.matches(in: "so b a la kumar here", rule: rule).isEmpty)
    }

    @Test func longerTermWinsAtTheSameWord() throws {
        let rule = Rule(name: "N", terms: ["Bala", "Bala Kumar"])
        let results = RuleEngine.matches(in: "hey bala kumar here", rule: rule)
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result.matchedText == "bala kumar")
        #expect(result.term == "Bala Kumar")
    }

    @Test func matchesDoNotOverlap() {
        let rule = Rule(name: "N", terms: ["bala bala", "bala"])
        let results = RuleEngine.matches(in: "bala bala bala", rule: rule)
        #expect(results.map(\.matchedText) == ["bala bala", "bala"])
        #expect(results.map(\.ordinal) == [1, 2])
    }

    // MARK: Selecting among overlapping matches

    @Test func theClosestReadingBeatsOverlappingOnesWithExtraWords() {
        // "so bala kumar" and "bala kumar is" are within two edits of "balakumar", but "bala kumar" is exact.
        let rule = Rule(name: "N", terms: ["Balakumar"])
        #expect(RuleEngine.matches(in: "so bala kumar", rule: rule).map(\.matchedText) == ["bala kumar"])
        #expect(RuleEngine.matches(in: "bala kumar is here", rule: rule).map(\.matchedText) == ["bala kumar"])
        #expect(RuleEngine.matches(in: "so bala kumar is", rule: rule).map(\.matchedText) == ["bala kumar"])
    }

    @Test func equalDistanceGoesToTheEarlierStart() {
        let rule = Rule(name: "N", terms: ["bala kumar", "kumar singh"])
        #expect(RuleEngine.matches(in: "bala kumar singh", rule: rule).map(\.matchedText) == ["bala kumar"])
    }

    @Test func ordinalsFollowReadingOrderNotSelectionOrder() {
        // "bala" (distance 0) is selected before "ball" (distance 1), but "ball" is heard first.
        let rule = Rule(name: "N", terms: ["Bala"], sensitivity: .loose)
        let results = RuleEngine.matches(in: "ball and bala", rule: rule)
        #expect(results.map(\.matchedText) == ["ball", "bala"])
        #expect(results.map(\.ordinal) == [1, 2])
    }

    // MARK: Matched text and context

    @Test func contextTruncation() {
        let words = (1...25).map { $0 == 12 ? "Bala" : "w\($0)" }
        let results = RuleEngine.matches(in: words.joined(separator: " "), rule: bala)
        #expect(results.count == 1)
        let context = results.first?.context ?? ""
        #expect(context.hasPrefix("\u{2026}"))
        #expect(context.hasSuffix("\u{2026}"))
        let inside = context.replacingOccurrences(of: "\u{2026}", with: "").split(separator: " ").map(String.init)
        let position = inside.firstIndex(of: "Bala")
        #expect(position == 8)  // eight words before it,
        #expect(inside.count - 1 - (position ?? 0) == 8)  // and eight after
        #expect(inside.first == "w4")
        #expect(inside.last == "w20")
    }

    @Test func contextIsOnlyTruncatedWhereTheTextContinues() {
        let words = (1...12).map { $0 == 3 ? "Bala" : "w\($0)" }
        let context = RuleEngine.matches(in: words.joined(separator: " "), rule: bala).first?.context ?? ""
        #expect(!context.hasPrefix("\u{2026}"))  // two words before it: nothing cut at the start
        #expect(context.hasSuffix("w11\u{2026}"))  // nine after it: the last one is cut
        #expect(context.hasPrefix("w1 w2 Bala"))
    }

    @Test func matchedTextAndContextKeepTheOriginalCasingAndPunctuation() throws {
        let text = "OK, so BALA... can you \u{2014} share? Thanks!"
        let result = try #require(RuleEngine.matches(in: text, rule: bala).first)
        #expect(result.matchedText == "BALA")
        #expect(result.context == "OK, so BALA... can you \u{2014} share? Thanks")
    }

    @Test func possessiveStillMatchesAndStaysInTheContext() throws {
        let result = try #require(RuleEngine.matches(in: "Bala's deck", rule: bala).first)
        #expect(result.matchedText == "Bala")
        #expect(result.context == "Bala's deck")
    }

    // MARK: Helpers

    @Test func matchesHelper() throws {
        let results = RuleEngine.matches(in: "Bala and Bala", rule: bala)
        #expect(results.count == 2)
        #expect(results.map(\.ordinal) == [1, 2])
        let first = try #require(results.first)
        #expect(first.ruleID == bala.id)
        #expect(first.term == "Bala")
        #expect(first.matchedText == "Bala")
        #expect(first.context == "Bala and Bala")
        #expect(results.allSatisfy { !$0.fromAlternative })
    }

    @Test func matchesHelperIgnoresWhetherTheRuleIsEnabled() {
        var disabled = bala
        disabled.isEnabled = false
        #expect(RuleEngine.matches(in: "Bala", rule: disabled).count == 1)
    }

    @Test func hintsUniqueEnabledCapped() {
        let first = Rule(name: "A", terms: ["Bala", "Balakumar"])
        let second = Rule(name: "B", terms: ["stand up", "BALA"])
        let off = Rule(name: "C", terms: ["x"], isEnabled: false)
        let many = Rule(name: "D", terms: (0..<150).map { "term\($0)" })
        let hints = RuleEngine.hints(for: [first, second, off, many])
        #expect(Array(hints.prefix(3)) == ["Bala", "Balakumar", "stand up"])
        #expect(hints.count <= 100)
        #expect(!hints.contains("x"))
    }

    @Test func hintsAreTrimmedAndNeverEmpty() {
        let rule = Rule(name: "A", terms: ["  Bala ", "   ", "", "\nbala\t", "Priya"])
        #expect(RuleEngine.hints(for: [rule]) == ["Bala", "Priya"])
    }

    // MARK: Performance

    /// A long update must cost time in proportion to its length: each word is compared against every term only
    /// with the few words next to it, never with the whole rest of the text.
    @Test func evaluationGrowsLinearlyWithTheTextLength() {
        let vocabulary = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "stand", "up", "meeting"]
        let rules = (0..<10).map { index in
            Rule(
                name: "Rule \(index)",
                terms: (0..<5).map { "Name\(index)x\($0) Surname\($0)" },
                sensitivity: Sensitivity.allCases[index % 3])
        }
        var engine = RuleEngine(rules: rules)
        var words = (0..<1_800).map { vocabulary[$0 % vocabulary.count] }
        words[1_500] = "name3x2"
        words[1_501] = "surname2"
        let reversed = words.reversed().joined(separator: " ")
        let update = segment("s1", words.joined(separator: " "), alternatives: [reversed])
        #expect(update.text.count > 8_000)

        let clock = ContinuousClock()
        var hits: [Hit] = []
        let elapsed = clock.measure { hits = engine.hear(update, at: t0) }
        #expect(hits.contains { $0.ruleName == "Rule 3" })  // the exact rule finds the planted name
        #expect(elapsed < .seconds(10), "took \(elapsed)")
    }
}
