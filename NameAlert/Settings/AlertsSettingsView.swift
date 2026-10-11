import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Settings → Alerts: one section for each way of being alerted, with its settings, a Test button and the last failed
/// delivery.
struct AlertsSettingsView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(SecretsModel.self) private var secrets

    @State private var failures = ChannelFailures()

    var body: some View {
        Form {
            SoundSection()
            NotificationSection()
            AlarmSection()
            ScreenFlashSection()
            NtfySection()
            TelegramSection()
            WebhookSection()
        }
        .formStyle(.grouped)
        .environment(failures)
        .task {
            // Which secrets are saved, so that their fields can say "Saved".
            secrets.refresh(Self.secretAccounts(for: controller.configuration.channels))
            // A delivery can fail while this is open, so look again from time to time.
            while !Task.isCancelled {
                await failures.refresh(from: controller)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear { secrets.commitAll() }
    }

    /// The Keychain accounts of every secret the Alerts settings keep.
    static func secretAccounts(for channels: ChannelSettings) -> [String] {
        [SecretAccount.ntfyToken, SecretAccount.webhookSigningSecret]
            + channels.webhook.headerNames.map(SecretAccount.webhookHeader)
    }
}
