import Foundation
import NameAlertCore
import Testing

/// A rule that listens for its own name and alerts with `channels`.
private func rule(
    _ name: String, terms: [String]? = nil, channels: Set<ChannelKind> = [.sound], isEnabled: Bool = true
) -> Rule {
    Rule(name: name, terms: terms ?? [name], channels: channels, isEnabled: isEnabled)
}

@Suite("ProPolicy")
struct ProPolicyTests {
    private let free = ProPolicy(access: .free)
    private let pro = ProPolicy(access: .pro)

    @Test func freeAlertsWithTheFirstThreeRules() {
        let rules = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].map { rule($0) }
        let alerting = free.alertingRules(rules)
        #expect(alerting.map(\.id) == rules.map(\.id), "every rule is kept, in its place")
        #expect(alerting.map(\.isEnabled) == [true, true, true, false, false])
        #expect(free.heldBackRuleIDs(in: rules) == [rules[3].id, rules[4].id])
    }

    @Test func rulesThatCannotAlertDoNotUseUpTheFreeRules() {
        let off = rule("Off", isEnabled: false)
        let noWords = rule("No words", terms: [])
        let onlyPunctuation = rule("Punctuation", terms: ["!!!"])
        let rest = ["Delta", "Echo", "Foxtrot", "Golf"].map { rule($0) }
        let rules = [off, noWords, onlyPunctuation] + rest
        #expect(free.heldBackRuleIDs(in: rules) == [rest[3].id])
        #expect(free.alertingRules(rules).map(\.isEnabled) == [false, true, true, true, true, true, false])
    }

    @Test func turningARuleOffLetsTheNextOneAlert() {
        var rules = ["Alpha", "Bravo", "Charlie", "Delta"].map { rule($0) }
        #expect(free.heldBackRuleIDs(in: rules) == [rules[3].id])
        rules[1].isEnabled = false
        #expect(free.heldBackRuleIDs(in: rules).isEmpty)
    }

    @Test func theNameRuleThatSetupPutsFirstAlertsAndTheLastRuleWaits() {
        // Running setup again with three rules inserts the name rule at the top.
        let others = ["Bravo", "Charlie", "Delta"].map { rule($0) }
        let rules = [rule("My name", terms: ["Bala"])] + others
        #expect(free.heldBackRuleIDs(in: rules) == [others[2].id])
    }

    @Test func freeSendsOnlyTheAlertsThatStayOnTheMac() {
        let everything = Set(ChannelKind.allCases)
        let rules = [rule("Alpha", channels: everything), rule("Bravo", channels: [.webhook])]
        let alerting = free.alertingRules(rules)
        #expect(alerting[0].channels == [.sound, .notification, .persistentAlarm, .screenFlash])
        #expect(alerting[1].channels.isEmpty)
        #expect(ChannelKind.allCases.filter { !free.allows($0) } == [.ntfy, .telegramCall, .webhook])
        #expect(free.heldBackChannels(of: rules[0]) == [.ntfy, .telegramCall, .webhook])
        #expect(free.heldBackChannels(of: rule("Charlie", channels: [.sound])).isEmpty)
    }

    @Test func proChangesNothing() {
        let rules = (1...12).map { rule("Rule \($0)", channels: Set(ChannelKind.allCases)) }
        #expect(pro.alertingRules(rules) == rules)
        #expect(pro.heldBackRuleIDs(in: rules).isEmpty)
        #expect(pro.heldBackChannels(of: rules[0]).isEmpty)
        #expect(ChannelKind.allCases.allSatisfy { pro.allows($0) })
        #expect(pro.canAddRule(to: rules))
    }

    @Test func freeAddsRulesUpToThreeInAll() {
        #expect(ProPolicy.freeRuleLimit == 3)
        #expect(free.canAddRule(to: []))
        #expect(free.canAddRule(to: [rule("Alpha"), rule("Bravo")]))
        #expect(!free.canAddRule(to: [rule("Alpha"), rule("Bravo"), rule("Off", isEnabled: false)]))
    }

    @Test func aRuleCanAlertWhenItIsOnAndHasAWordToHear() {
        #expect(RuleEngine.canFire(rule("Alpha")))
        #expect(!RuleEngine.canFire(rule("Alpha", isEnabled: false)))
        #expect(!RuleEngine.canFire(rule("Empty", terms: [])))
        #expect(!RuleEngine.canFire(rule("Blank", terms: ["  ", "…"])))
        #expect(RuleEngine.canFire(rule("Room", terms: ["101"])))
    }

    @Test func theProductOnSale() {
        #expect(ProProduct.id == "dev.balakumar.namealert.pro")
    }

    @Test func aChannelThatNeedsProSaysSo() {
        #expect(ProFeatureError.needsPro(.ntfy).localizedDescription == "This alert is part of Pro.")
    }
}
