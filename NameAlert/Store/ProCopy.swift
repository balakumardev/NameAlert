import NameAlertCore

/// The words of everything that sells Pro. Prices always come from the App Store (`ProStore.displayPrice`), never from
/// here, and the app's name from `AppInfo.displayName`.
enum ProCopy {
    static var title: String { "\(AppInfo.displayName) Pro" }
    static let tagline = "One purchase. Yours for good."
    static var proAdds: [String] {
        [
            "Unlimited rules. Free alerts with up to \(ProPolicy.freeRuleLimit).",
            "Alerts that reach your phone and other devices: ntfy push, Telegram calls and webhooks.",
        ]
    }
    static let freeKeeps =
        "Free keeps every alert on this Mac (sound, notification, alarm and screen flash), History, Shortcuts and links."
    static let oneTime = "A one-time purchase: no subscription, nothing renews."
    static let restoreHint = "Bought it on another Mac? Restore Purchases brings it here."

    static func buyTitle(price: String) -> String { "Buy Pro for \(price)" }
    static let restoreTitle = "Restore Purchases"
    static let notNow = "Not Now"
    static let unlockTitle = "Unlock Pro…"
    static let seeProTitle = "See Pro…"
    static let badge = "Pro"
    static let termsTitle = "Terms of Use"
    static let privacyTitle = "Privacy Policy"
    static let tryAgain = "Try Again"

    // What the purchase is doing.
    static let checking = "Checking your purchase…"
    static let loadingPrice = "Loading the price…"
    static let priceDidNotLoad = "The price didn't load. Check the connection and try again."
    static let pending = "Waiting for approval. Pro turns on as soon as it's approved."
    static var owned: String { "Pro is on. Thank you for supporting \(AppInfo.displayName)." }
    static let restored = "Your purchase is restored."
    static let nothingFound = "No Pro purchase was found for the Apple Account this Mac uses for the App Store."
    static let unverifiedPurchase = "The App Store couldn't confirm the purchase, so Pro stays off. Try Restore Purchases."
    static func purchaseFailed(_ error: any Error) -> String {
        "The purchase didn't go through: \(error.localizedDescription)"
    }
    static func restoreFailed(_ error: any Error) -> String { "Couldn't restore: \(error.localizedDescription)" }

    // Where a free limit is reached.
    static let ruleLimitTitle = "Add more rules with Pro"
    static var ruleLimitMessage: String {
        "Free alerts with up to \(ProPolicy.freeRuleLimit) rules. Pro removes the limit, and adds alerts that reach your phone."
    }
    static func channelTitle(_ kind: ChannelKind) -> String { "\(kind.displayName) is part of Pro" }
    static let channelMessage =
        "Pro adds alerts that reach your phone and other devices (ntfy push, Telegram calls and webhooks), and removes the rule limit."
    static var ruleHeldBack: String {
        "This rule doesn't alert on Free. Free alerts with the first \(ProPolicy.freeRuleLimit) rules that are on: turn another one off, or get Pro."
    }
    static let channelNotSentOnFree = "Not sent on Free."
    static let channelSectionNote = "Part of Pro. What you set up here is kept."
    static let testNeedsPro = "Needs Pro."
    static var popoverRuleLimit: String {
        "Free alerts with up to \(ProPolicy.freeRuleLimit) rules. Add words to a rule in Settings, or get Pro."
    }
    static let webhookIsPro = "Webhook alerts are part of Pro."
}
