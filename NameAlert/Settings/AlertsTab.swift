import SwiftUI

struct AlertsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: ListeningEngine

    var body: some View {
        Form {
            beepSection
            notificationSection
            persistentSection
            ntfySection
            callMeBotSection
        }
        .formStyle(.grouped)
        .padding()
    }

    private var beepSection: some View {
        Section("System Beep") {
            Toggle("Enabled", isOn: $settings.beepEnabled)
                .onChange(of: settings.beepEnabled) { _, _ in refresh() }
            Picker("Sound", selection: $settings.beepSoundName) {
                ForEach(BeepAlert.systemSoundNames, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: settings.beepSoundName) { _, _ in refresh() }
            Button("Test Beep") {
                Task { await engine.test(BeepAlert(soundName: settings.beepSoundName)) }
            }
        }
    }

    private var notificationSection: some View {
        Section("macOS Notification") {
            Toggle("Enabled", isOn: $settings.notificationEnabled)
                .onChange(of: settings.notificationEnabled) { _, _ in refresh() }
            Button("Test Notification") {
                Task {
                    await NotificationAlert.requestAuthorizationIfNeeded()
                    await engine.test(NotificationAlert())
                }
            }
        }
    }

    private var persistentSection: some View {
        Section("Persistent Alert (loops until dismissed)") {
            Toggle("Enabled", isOn: $settings.persistentEnabled)
                .onChange(of: settings.persistentEnabled) { _, _ in refresh() }
            Picker("Sound", selection: $settings.persistentSoundName) {
                ForEach(BeepAlert.systemSoundNames, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: settings.persistentSoundName) { _, _ in refresh() }
            Text("Loops the chosen sound and shows a dialog. Sound stops when you tap Dismiss.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Test Persistent Alert") {
                Task { await engine.test(PersistentAlert(soundName: settings.persistentSoundName)) }
            }
        }
    }

    private var ntfySection: some View {
        Section("ntfy.sh Push") {
            Toggle("Enabled", isOn: $settings.ntfyEnabled)
                .onChange(of: settings.ntfyEnabled) { _, _ in refresh() }
            TextField("Server", text: $settings.ntfyServer)
                .onChange(of: settings.ntfyServer) { _, _ in refresh() }
            TextField("Topic", text: $settings.ntfyTopic)
                .onChange(of: settings.ntfyTopic) { _, _ in refresh() }
            SecureField("Auth Token (optional)", text: $settings.ntfyAuthToken)
                .onChange(of: settings.ntfyAuthToken) { _, _ in refresh() }
            Button("Test Push") {
                let alert = NtfyAlert(
                    server: settings.ntfyServer,
                    topic: settings.ntfyTopic,
                    authToken: settings.ntfyAuthToken.isEmpty ? nil : settings.ntfyAuthToken
                )
                Task { await engine.test(alert) }
            }
            .disabled(settings.ntfyTopic.isEmpty)
        }
    }

    private var callMeBotSection: some View {
        Section("CallMeBot Telegram Call") {
            Toggle("Enabled", isOn: $settings.callMeBotEnabled)
                .onChange(of: settings.callMeBotEnabled) { _, _ in refresh() }
            TextField("Telegram username (e.g. @you) or +phone", text: $settings.callMeBotUser)
                .onChange(of: settings.callMeBotUser) { _, _ in refresh() }
            TextField("Message ({keyword}, {text})", text: $settings.callMeBotMessage)
                .onChange(of: settings.callMeBotMessage) { _, _ in refresh() }
            TextField("Voice", text: $settings.callMeBotLanguage)
                .onChange(of: settings.callMeBotLanguage) { _, _ in refresh() }
            Button("Test Call") {
                let alert = CallMeBotAlert(
                    user: settings.callMeBotUser,
                    messageTemplate: settings.callMeBotMessage,
                    language: settings.callMeBotLanguage
                )
                Task { await engine.test(alert) }
            }
            .disabled(settings.callMeBotUser.isEmpty)
        }
    }

    private func refresh() { Task { await engine.refreshConfiguration() } }
}
