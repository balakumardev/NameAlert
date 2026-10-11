import NameAlertCore

extension ChannelKind {
    /// The name people see for a way of being alerted.
    var displayName: String {
        switch self {
        case .sound: "Sound"
        case .notification: "Notification"
        case .persistentAlarm: "Alarm until dismissed"
        case .screenFlash: "Screen flash"
        case .ntfy: "ntfy push"
        case .telegramCall: "Telegram call"
        case .webhook: "Webhook"
        }
    }
}
