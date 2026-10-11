import Foundation
import NameAlertCore
import UserNotifications

/// The notification buttons, and the notification permission.
///
/// `register()` once at launch makes the "HIT" category known, so that a hit's notification gets the **Snooze 15 min**
/// and **Open History** buttons. The app answers a tap on them in its notification delegate, using the IDs here.
public enum NotificationActions {
    public static let categoryID = "HIT"
    public static let snoozeActionID = "SNOOZE_15"
    public static let openHistoryActionID = "OPEN_HISTORY"

    private static let logger = Log.logger("notifications")

    /// Makes the notification category known to the system. NameAlert has only this one, so it replaces the others.
    public static func register() {
        UNUserNotificationCenter.current().setNotificationCategories([makeCategory()])
    }

    /// Asks for permission to show alerts and play sounds, unless the user has decided already. Returns whether
    /// notifications are allowed.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("The notification permission could not be asked for: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What the user has decided so far. It never shows a prompt.
    public static func status() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return permissionStatus(for: settings.authorizationStatus)
    }

    static func makeCategory() -> UNNotificationCategory {
        let snooze = UNNotificationAction(identifier: snoozeActionID, title: "Snooze 15 min", options: [])
        // Opening the history needs the app in front.
        let openHistory = UNNotificationAction(identifier: openHistoryActionID, title: "Open History", options: [.foreground])
        return UNNotificationCategory(
            identifier: categoryID, actions: [snooze, openHistory], intentIdentifiers: [], options: [])
    }

    /// Quiet ("provisional") permission still delivers notifications, so it counts.
    static func permissionStatus(for status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
