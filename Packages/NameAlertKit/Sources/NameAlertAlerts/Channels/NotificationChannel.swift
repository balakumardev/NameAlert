import Foundation
import NameAlertCore
import UserNotifications

/// Posts a macOS notification: `Heard “<term>”` with the words around it and, when the hit has an excerpt, the end of
/// what was said just before them on a second line (or the rule's name, when the user keeps the context out of
/// notifications).
///
/// The notifications of one rule are grouped in a thread, and carry the "HIT" category with its Snooze and Open
/// History buttons (see `NotificationActions`). Whether macOS shows them is up to the user's notification settings;
/// adding a notification does not fail when they are off.
///
/// A notification makes no sound of its own: the Sound channel plays the alert sound at the volume the user picked, so
/// a hit that uses both is heard once.
public struct NotificationChannel: AlertChannel {
    public var kind: ChannelKind { .notification }

    /// The most characters of the excerpt that a notification shows: a banner has room for a few lines only.
    static let excerptLimit = 120

    public init() {}

    public static func makeContent(for hit: Hit, settings: NotificationSettings) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Heard “\(hit.term)”"
        content.body = bodyText(for: hit, includeContext: settings.includeContext)
        content.categoryIdentifier = NotificationActions.categoryID
        content.threadIdentifier = hit.ruleID.uuidString
        content.userInfo = ["ruleID": hit.ruleID.uuidString]
        return content
    }

    /// The text under the title. With the context switched off it is the rule's name, so that nothing that was heard
    /// shows (the excerpt included). With it on, it is the words around the term and, on a line of its own under them,
    /// the end of the excerpt. When one of those two is missing the other stands alone, and with neither it is the
    /// rule's name.
    static func bodyText(for hit: Hit, includeContext: Bool) -> String {
        guard includeContext else { return hit.ruleName }
        let around = hit.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hit.context
        switch (around, endOfExcerpt(hit.excerpt)) {
        case let (around?, before?): return around + "\n" + before
        case let (around?, nil): return around
        case let (nil, before?): return before
        case (nil, nil): return hit.ruleName
        }
    }

    /// `excerpt` without the spaces around it; when that is longer than `excerptLimit` characters, only its last
    /// `excerptLimit` characters, with "…" in front to show that the start is cut off (a character here is what a
    /// reader sees as one, so an emoji is never cut in half). `nil` when there is nothing in it.
    static func endOfExcerpt(_ excerpt: String?) -> String? {
        guard let text = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > excerptLimit ? "…" + String(text.suffix(excerptLimit)) : text
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: Self.makeContent(for: hit, settings: settings.notification),
            trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
