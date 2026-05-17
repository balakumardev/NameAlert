import Foundation
import UserNotifications

/// Posts a `UNUserNotification` with the matched phrase.
struct NotificationAlert: Alert {
    let id = "notification"
    let displayName = "macOS Notification"

    func fire(reason: Hit) async {
        let content = UNMutableNotificationContent()
        content.title = "Heard \"\(reason.keyword)\""
        content.body = reason.matchedText
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("NotificationAlert failed: \(error.localizedDescription)")
        }
    }

    /// Request authorization. Safe to call repeatedly.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("Notification auth failed: \(error.localizedDescription)")
        }
    }
}
