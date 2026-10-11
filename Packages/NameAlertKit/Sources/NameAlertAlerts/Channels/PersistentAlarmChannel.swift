import Foundation
import NameAlertCore

/// Shows a floating alarm panel and loops a sound until the user dismisses or snoozes it (or it stops by itself after
/// the time in the settings). See `AlarmPanel`.
///
/// `onSnooze` is called with 15 when the user presses **Snooze 15 min**.
public struct PersistentAlarmChannel: AlertChannel {
    public var kind: ChannelKind { .persistentAlarm }

    private let onSnooze: @Sendable (Int) async -> Void

    public init(onSnooze: @escaping @Sendable (Int) async -> Void) {
        self.onSnooze = onSnooze
    }

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        let alarm = settings.persistentAlarm
        let onSnooze = onSnooze
        await MainActor.run { AlarmPanel.shared.present(hit, settings: alarm, onSnooze: onSnooze) }
    }
}
