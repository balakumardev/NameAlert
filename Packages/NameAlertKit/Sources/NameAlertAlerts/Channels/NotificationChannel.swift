import Foundation
import NameAlertCore
import UserNotifications

/// Posts a macOS notification: `Heard “<term>”` with the words around it (or the rule's name, when the user keeps the
/// context out of notifications).
///
/// The notifications of one rule are grouped in a thread, and carry the "HIT" category with its Snooze and Open
/// History buttons (see `NotificationActions`). Whether macOS shows them is up to the user's notification settings;
/// adding a notification does not fail when they are off.
public struct NotificationChannel: AlertChannel {
    public var kind: ChannelKind { .notification }

    public init() {}

    public static func makeContent(for hit: Hit, settings: NotificationSettings) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Heard “\(hit.term)”"
        let heard = hit.context.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = settings.includeContext && !heard.isEmpty ? hit.context : hit.ruleName
        content.sound = .default
        content.categoryIdentifier = NotificationActions.categoryID
        content.threadIdentifier = hit.ruleID.uuidString
        content.userInfo = ["ruleID": hit.ruleID.uuidString]
        return content
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: Self.makeContent(for: hit, settings: settings.notification),
            trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
