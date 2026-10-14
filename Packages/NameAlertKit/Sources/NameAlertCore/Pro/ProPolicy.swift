import Foundation

/// Whether this copy of the app has Pro. A build that does not sell Pro (the Developer ID disk image, a build from
/// source) always runs as `.pro`: everything is on.
public enum ProAccess: String, Codable, Sendable, CaseIterable {
    case free, pro
}

/// The one product the app sells.
public enum ProProduct {
    /// The non-consumable "lifetime" unlock. App Store Connect never lets a product ID change or be used again.
    public static let id = "dev.balakumar.namealert.pro"
}

/// What Free and Pro may do: the one place that decides it.
///
/// Free alerts with up to `freeRuleLimit` rules and with every alert that stays on this Mac. Pro removes the rule limit
/// and adds the alerts that reach other devices (`proChannels`). Nothing here changes what is saved: a rule or a channel
/// that Free does not allow is kept and only does not alert, and buying Pro again brings it back as it was.
public struct ProPolicy: Sendable, Equatable {
    /// The most rules Free alerts with: the name rule from setup and two more.
    public static let freeRuleLimit = 3
    /// The alerts that leave the Mac for another device or service.
    public static let proChannels: Set<ChannelKind> = [.ntfy, .telegramCall, .webhook]

    public let access: ProAccess

    public init(access: ProAccess) {
        self.access = access
    }

    public var isPro: Bool { access == .pro }

    /// Whether alerts of `kind` may be sent, tests included.
    public func allows(_ kind: ChannelKind) -> Bool {
        isPro || !Self.proChannels.contains(kind)
    }

    /// Whether one more rule may be added to `rules`. Free counts every rule, on or off.
    public func canAddRule(to rules: [Rule]) -> Bool {
        isPro || rules.count < Self.freeRuleLimit
    }

    /// The rules that can alert (turned on, with a word to hear; see `RuleEngine.canFire`) past the first
    /// `freeRuleLimit` of them, in list order: Free holds them back. Empty on Pro.
    public func heldBackRuleIDs(in rules: [Rule]) -> Set<UUID> {
        guard !isPro else { return [] }
        var heldBack: Set<UUID> = []
        var allowed = Self.freeRuleLimit
        for rule in rules where RuleEngine.canFire(rule) {
            if allowed > 0 {
                allowed -= 1
            } else {
                heldBack.insert(rule.id)
            }
        }
        return heldBack
    }

    /// Whether `rule` alerts only in ways Free does not send (ntfy, a Telegram call, a webhook): on Free it is heard and kept
    /// in History, and alerts nowhere. Always `false` on Pro.
    public func alertsOnlyThroughPro(_ rule: Rule) -> Bool {
        !isPro && !rule.channels.isEmpty && rule.channels.isSubset(of: Self.proChannels)
    }

    /// The channels of `rule` that Free does not send. Empty on Pro.
    public func heldBackChannels(of rule: Rule) -> Set<ChannelKind> {
        isPro ? [] : rule.channels.intersection(Self.proChannels)
    }

    /// `rules` as they alert under this policy, in the same order: on Free a held-back rule is turned off and every rule
    /// loses the channels Free does not send; on Pro, `rules` as they are. The listening controller gives this to the
    /// rule engine, the speech engine's hints and the alert dispatcher.
    public func alertingRules(_ rules: [Rule]) -> [Rule] {
        guard !isPro else { return rules }
        let heldBack = heldBackRuleIDs(in: rules)
        return rules.map { rule in
            var rule = rule
            rule.channels.subtract(Self.proChannels)
            if heldBack.contains(rule.id) { rule.isEnabled = false }
            return rule
        }
    }
}

/// Something Free does not do was asked for.
public enum ProFeatureError: Error, Equatable, Sendable {
    /// An alert of this kind leaves the Mac, which needs Pro.
    case needsPro(ChannelKind)
}

extension ProFeatureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .needsPro: "This alert is part of Pro."
        }
    }
}
