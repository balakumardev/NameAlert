import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import Observation
import SwiftUI

// MARK: - What every channel's section shares

/// The latest failed delivery of each channel, as the alert dispatcher recorded it.
@MainActor
@Observable
final class ChannelFailures {
    private(set) var failures: [ChannelKind: DeliveryFailure] = [:]

    func refresh(from controller: ListeningController) async {
        let latest = await controller.lastDeliveryFailures()
        if latest != failures { failures = latest }
    }
}

/// The Test button of a channel's section: it sends a sample alert to that channel and says "Sent" or why it failed,
/// and under it, in red, the last delivery that failed.
struct ChannelTestRow: View {
    let kind: ChannelKind

    @Environment(ListeningController.self) private var controller
    @Environment(SecretsModel.self) private var secrets
    @Environment(ChannelFailures.self) private var failures

    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle, sending, sent
        case failed(String)
    }

    var body: some View {
        let blocked = Self.blockedReason(
            for: kind, channels: controller.configuration.channels, notifications: controller.permissions.notifications)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Test", action: run)
                    .disabled(phase == .sending || blocked != nil)
                    .accessibilityLabel("Send a test \(kind.displayName) alert")
                status(blocked: blocked)
            }
            if case .failed(let reason) = phase {
                SettingsCaption("Couldn't send: \(reason)", isError: true)
            }
            if let line = Self.lastFailureLine(failures.failures[kind], phase: phase) {
                SettingsCaption(line, isError: true)
            }
        }
        .task(id: phase) {
            // "Sent" goes away by itself.
            guard phase == .sent else { return }
            try? await Task.sleep(for: .seconds(4))
            if phase == .sent { phase = .idle }
        }
    }

    @ViewBuilder
    private func status(blocked: String?) -> some View {
        switch phase {
        case .idle:
            if let blocked {
                Text(verbatim: blocked)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .sending:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Sending")
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed:
            EmptyView()
        }
    }

    private func run() {
        phase = .sending
        Task {
            // What was typed a moment ago counts: a secret still in its field, and settings the controller is about to
            // make.
            secrets.commitAll()
            await controller.finishPendingEdits()
            do {
                try await controller.testAlert(kind)
                phase = .sent
                AccessibilityNotification.Announcement("Sent").post()
            } catch is CancellationError {
                phase = .idle
            } catch {
                let reason = Self.reason(for: error)
                phase = .failed(reason)
                AccessibilityNotification.Announcement("Couldn't send: \(reason)").post()
            }
            await failures.refresh(from: controller)
        }
    }

    /// Why a test cannot be sent yet, or `nil` when it can.
    static func blockedReason(
        for kind: ChannelKind, channels: ChannelSettings, notifications: PermissionStatus
    ) -> String? {
        if kind == .notification, notifications != .granted { return "Turn on notifications first." }
        return channels.isConfigured(kind) ? nil : "Fill in the settings above to test."
    }

    /// What went wrong, the way the dispatcher words it for "Last delivery failed", so that the two can be compared.
    static func reason(for error: any Error) -> String {
        DeliveryFailure.reason(for: error)
    }

    /// "Last delivery failed: HTTP 404 (10:32)", unless the test that just failed has said the same.
    static func lastFailureLine(_ failure: DeliveryFailure?, phase: Phase, now: Date = Date()) -> String? {
        guard let failure else { return nil }
        if case .failed(let reason) = phase, reason == failure.reason { return nil }
        return "Last delivery failed: \(failure.reason) (\(HitRow.time(of: failure.date, now: now)))"
    }
}

/// Whether an address can be used for an alert, and what to tell the user when it cannot.
enum AddressCheck {
    static let httpsHint = "Use https (http works only on your local network)."
    static let incompleteHint = "Enter a full address, like https://example.com."

    /// Whether `address` is one an alert may be sent to. The rule lives in `ChannelSettings`; this asks it, so that the
    /// note under a field and the channel's Test button never disagree.
    static func isUsable(_ address: String) -> Bool {
        var probe = ChannelSettings()
        probe.webhook.url = address
        return probe.isConfigured(.webhook)
    }

    /// The note for a field holding `address`: `nil` while it is empty or fine.
    static func message(for address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isUsable(trimmed) else { return nil }
        return trimmed.lowercased().hasPrefix("http://") ? httpsHint : incompleteHint
    }
}

/// The names of custom webhook headers.
enum HeaderName {
    static let invalidMessage = "Header names use letters, numbers and dashes, with no spaces or colons."
    static let duplicateMessage = "That header is already added."

    /// A name an HTTP header can have: letters and digits, and the punctuation HTTP allows (no spaces, no colon).
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }
    }

    /// What is wrong with `name` as a new header next to the `existing` ones; `nil` when nothing is, or it is empty.
    static func message(for name: String, existing: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isValid(trimmed) else { return invalidMessage }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return duplicateMessage }
        return nil
    }
}

/// The line under each channel that sends words off this Mac: what goes, and to whom.
enum LeavesTheMacNote {
    /// `plusExcerpt` is for a channel that also sends what was said up to 30 seconds before the mention (the hit's
    /// excerpt, whose window is `TranscriptMemory.excerptWindow`).
    static func text(sendingTo service: String, plusExcerpt: Bool = false) -> String {
        plusExcerpt
            ? "Sends the words around the mention, plus up to 30 seconds before it, to \(service)."
            : "Sends the words around the mention to \(service)."
    }

    // ntfy's message is the words around the mention; the excerpt only takes their place when there are none.
    static let ntfy = text(sendingTo: "ntfy")
    static let telegramCall = text(sendingTo: "CallMeBot")
    // The webhook's JSON has the excerpt next to the context.
    static let webhook = text(sendingTo: "your webhook", plusExcerpt: true)
}

/// The sound names a picker offers: every system sound, and the one in use if it is not among them.
enum SoundChoices {
    static func names(including current: String) -> [String] {
        SystemSounds.names.contains(current) ? SystemSounds.names : SystemSounds.names + [current]
    }
}

// MARK: - Sound

struct SoundSection: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let sound = controller.configuration.channels.sound
        Section {
            Picker("Sound", selection: controller.binding(\.channels.sound.soundName)) {
                ForEach(SoundChoices.names(including: sound.soundName), id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            .accessibilityLabel("Alert sound")

            LabeledContent("Volume") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    DraftSlider("Volume", value: sound.volume, in: 0...1) { volume in
                        controller.edit { $0.channels.sound.volume = volume }
                    }
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }

            ChannelTestRow(kind: .sound)
        } header: {
            SettingsSectionTitle(ChannelKind.sound.displayName)
        }
    }
}

// MARK: - Notification

struct NotificationSection: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        Section {
            Toggle("Show what was said", isOn: controller.binding(\.channels.notification.includeContext))
                .accessibilityLabel("Show what was said")

            if controller.permissions.notifications != .granted {
                NotificationPermissionRow()
            }

            ChannelTestRow(kind: .notification)
        } header: {
            SettingsSectionTitle(ChannelKind.notification.displayName)
        }
    }
}

/// "Notifications are off" with the button that turns them on: the system's question the first time, and after that, or
/// once the user has said no, the pane of System Settings where it can be changed. The same rule, and the same words,
/// as the menu bar popover's note (`PermissionOffer`, `NotificationsOffNotice`).
struct NotificationPermissionRow: View {
    /// Which permissions were asked for already; the app's own unless a test brings one.
    var asks: PermissionAsks = .shared

    @Environment(ListeningController.self) private var controller

    var body: some View {
        let offer = Self.offer(for: controller.permissions.notifications, asks: asks)
        HStack(spacing: 8) {
            Label {
                Text(verbatim: StatusText.title(for: ListeningIssue.permissionDenied(.notifications)))
            } icon: {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button(NotificationsOffNotice.title(for: offer)) {
                if offer == .allow {
                    Task { await controller.ask(for: .notifications, asks: asks) }
                } else {
                    SystemSettingsLink.open(.notifications)
                }
            }
            .accessibilityLabel(
                offer == .allow ? "Turn on notifications" : "Open System Settings to turn on notifications")
        }
    }

    /// What the button offers: the system's question until it has been asked, then System Settings.
    static func offer(for status: PermissionStatus, asks: PermissionAsks) -> PermissionOffer {
        PermissionOffer(kind: .notifications, status: status, hasAsked: asks.hasAsked(.notifications))
    }
}

// MARK: - Alarm until dismissed

struct AlarmSection: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let alarm = controller.configuration.channels.persistentAlarm
        Section {
            Picker("Sound", selection: controller.binding(\.channels.persistentAlarm.soundName)) {
                ForEach(SoundChoices.names(including: alarm.soundName), id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            .accessibilityLabel("Alarm sound")

            Picker("Stop after", selection: controller.binding(\.channels.persistentAlarm.autoStopSeconds)) {
                ForEach(PersistentAlarmSettings.autoStopChoices, id: \.self) { seconds in
                    Text(verbatim: DurationText.short(Double(seconds))).tag(seconds)
                }
            }
            .accessibilityLabel("Stop the alarm after")

            ChannelTestRow(kind: .persistentAlarm)
        } header: {
            SettingsSectionTitle(ChannelKind.persistentAlarm.displayName)
        } footer: {
            SettingsCaption("Keeps playing until you dismiss it or the time is up.")
        }
    }
}

// MARK: - Screen flash

struct ScreenFlashSection: View {
    var body: some View {
        Section {
            ChannelTestRow(kind: .screenFlash)
        } header: {
            SettingsSectionTitle(ChannelKind.screenFlash.displayName)
        } footer: {
            SettingsCaption("Flashes a colored border around every screen for a moment.")
        }
    }
}

// MARK: - ntfy

struct NtfySection: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let ntfy = controller.configuration.channels.ntfy
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledTextField(title: "Server", value: ntfy.server, prompt: "https://ntfy.sh") { server in
                    controller.edit { $0.channels.ntfy.server = server }
                }
                if let message = AddressCheck.message(for: ntfy.server) {
                    SettingsCaption(message, isError: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledTextField(title: "Topic", value: ntfy.topic, prompt: "your-topic-name") { topic in
                    controller.edit { $0.channels.ntfy.topic = topic }
                }
                SettingsCaption("Anyone who knows the topic name can read these alerts.")
            }

            Picker("Priority", selection: controller.binding(\.channels.ntfy.priority)) {
                ForEach(NtfyPriority.allCases, id: \.self) { priority in
                    Text(verbatim: Self.title(for: priority)).tag(priority)
                }
            }
            .accessibilityLabel("ntfy priority")

            VStack(alignment: .leading, spacing: 4) {
                SecretField(title: "Access token", account: SecretAccount.ntfyToken)
                SettingsCaption("Only needed for a protected topic.")
            }

            ChannelTestRow(kind: .ntfy)
        } header: {
            SettingsSectionTitle(ChannelKind.ntfy.displayName)
        } footer: {
            SettingsCaption(LeavesTheMacNote.ntfy)
        }
    }

    static func title(for priority: NtfyPriority) -> String {
        switch priority {
        case .default: "Default"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }
}

// MARK: - Telegram call

struct TelegramSection: View {
    /// CallMeBot's page for Telegram calls: how to allow its bot, and the voices.
    static let setupAddress = URL(string: "https://www.callmebot.com/telegram-call-api/")

    @Environment(ListeningController.self) private var controller

    var body: some View {
        let call = controller.configuration.channels.telegramCall
        Section {
            LabeledTextField(
                title: "Telegram username or phone", value: call.user, prompt: "@username or +15551234567"
            ) { user in
                controller.edit { $0.channels.telegramCall.user = user }
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledTextField(title: "Message", value: call.messageTemplate) { template in
                    controller.edit { $0.channels.telegramCall.messageTemplate = template }
                }
                SettingsCaption(Self.placeholderNote)
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledTextField(title: "Voice", value: call.voice, prompt: "en-US-Standard-B") { voice in
                    controller.edit { $0.channels.telegramCall.voice = voice }
                }
                SettingsCaption("Use a Standard voice name, like en-US-Standard-B.")
            }

            VStack(alignment: .leading, spacing: 4) {
                SettingsCaption(
                    "Allow @CallMeBot_txtbot on Telegram first. \(AppInfo.displayName) places at most one call a minute.")
                if let setup = Self.setupAddress {
                    Link("CallMeBot setup", destination: setup)
                        .foregroundStyle(.tint)
                        .font(.callout)
                        .accessibilityLabel("Open the CallMeBot setup page")
                }
            }

            ChannelTestRow(kind: .telegramCall)
        } header: {
            SettingsSectionTitle(ChannelKind.telegramCall.displayName)
        } footer: {
            SettingsCaption(LeavesTheMacNote.telegramCall)
        }
    }

    /// What the message field says about its placeholders.
    static let placeholderNote = "{keyword}, {text} and {context} are replaced"
}

// MARK: - Webhook

struct WebhookSection: View {
    @Environment(ListeningController.self) private var controller
    @Environment(SecretsModel.self) private var secrets
    @Environment(\.settingsNavigation) private var navigation

    @State private var isAddingHeader = false
    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        let webhook = controller.configuration.channels.webhook
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledTextField(title: "URL", value: webhook.url, prompt: "https://example.com/hook") { url in
                    controller.edit { $0.channels.webhook.url = url }
                }
                if let message = AddressCheck.message(for: webhook.url) {
                    SettingsCaption(message, isError: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                SecretField(title: "Signing secret", account: SecretAccount.webhookSigningSecret)
                SettingsCaption("Signs each request, so your server can check where it came from.")
                Button("How to verify the signature") { navigation.show(.shortcuts) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.callout)
                    .accessibilityLabel("How to verify the signature, in Shortcuts and API")
            }

            headers(webhook.headerNames)

            ChannelTestRow(kind: .webhook)
        } header: {
            SettingsSectionTitle(ChannelKind.webhook.displayName)
        } footer: {
            SettingsCaption(LeavesTheMacNote.webhook)
        }
    }

    // MARK: Custom headers

    private func headers(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom headers")
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                SecretField(
                    title: name, account: SecretAccount.webhookHeader(name), emptyPrompt: "Value", allowsClear: false
                ) {
                    Button {
                        remove(name)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the \(name) header")
                    .accessibilityLabel("Remove the \(name) header")
                }
            }
            if isAddingHeader {
                addForm(existing: names)
            } else {
                if names.isEmpty {
                    SettingsCaption("For anything your server expects, like an API key.")
                }
                Button("Add header") { isAddingHeader = true }
                    .controlSize(.small)
                    .accessibilityLabel("Add a custom header")
            }
        }
    }

    private func addForm(existing: [String]) -> some View {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = HeaderName.message(for: name, existing: existing)
        let canAdd = !name.isEmpty && !value.isEmpty && problem == nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: $newName, prompt: Text("X-Api-Key").foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Header name")
                SecureField("Value", text: $newValue, prompt: Text("Value").foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Header value")
            }
            if let problem {
                SettingsCaption(problem, isError: true)
            }
            if let failure = secrets.errors[SecretAccount.webhookHeader(name)] {
                SettingsCaption(failure, isError: true)
            }
            HStack(spacing: 8) {
                Button("Add") { add(name: name, value: value) }
                    .disabled(!canAdd)
                    .accessibilityLabel("Add this header")
                Button("Cancel") { resetAddForm() }
                    .accessibilityLabel("Cancel adding a header")
            }
            .controlSize(.small)
        }
    }

    private func add(name: String, value: String) {
        let account = SecretAccount.webhookHeader(name)
        secrets.drafts[account] = value
        secrets.commit(account)
        // A header whose value could not be kept is not added.
        guard secrets.isSaved(account) else { return }
        controller.edit { $0.channels.webhook.headerNames.append(name) }
        resetAddForm()
    }

    private func remove(_ name: String) {
        controller.edit { configuration in
            configuration.channels.webhook.headerNames.removeAll { $0 == name }
        }
        secrets.clear(SecretAccount.webhookHeader(name))
    }

    private func resetAddForm() {
        isAddingHeader = false
        newName = ""
        newValue = ""
    }
}
