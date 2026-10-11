import Foundation

/// Makes the channels the app delivers alerts through.
public enum AlertChannelFactory {
    /// One channel of every kind, in the order of `ChannelKind`. `appVersion` and `build` go into the webhook's
    /// requests; `onSnooze` is called with the minutes when the user snoozes from the alarm panel.
    public static func makeAll(
        appVersion: String, build: String, onSnooze: @escaping @Sendable (Int) async -> Void
    ) -> [any AlertChannel] {
        [
            SoundChannel(),
            NotificationChannel(),
            PersistentAlarmChannel(onSnooze: onSnooze),
            ScreenFlashChannel(),
            NtfyChannel(),
            TelegramCallChannel(),
            WebhookChannel(appVersion: appVersion, build: build),
        ]
    }
}
