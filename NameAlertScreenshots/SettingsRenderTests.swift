import AppKit
import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import ServiceManagement
import SwiftUI
import Testing

@testable import ScreenshotHost

/// The Settings window at its minimum size, 760 × 540 points.
private let settingsSize = CGSize(width: 760, height: 540)

/// How long a render of Alerts or Speech lets the view's own requests (to the alert dispatcher, to the speech
/// engine picker) come back before the picture is taken.
private let settleTime = Duration.milliseconds(500)

@Suite("Settings renders", .serialized)
@MainActor
struct SettingsRenderTests {
    @Test("General renders in light and dark", arguments: [false, true])
    func general(dark: Bool) throws {
        let view = SettingsRenderFrame {
            SettingsView(section: .general)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
                .environment(\.loginItem, FakeLoginItem(status: .enabled))
        }
        try RenderHarness.render(
            view, size: settingsSize, name: "settings-general" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("General shows its notes: waiting for approval, a failure, and no call detection", arguments: [false, true])
    func generalNotes(dark: Bool) throws {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.listening.mode = .duringCalls
        let loginItem = FakeLoginItem(status: .requiresApproval)
        loginItem.registrationError = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        // What the pane says after a turn-on that fails.
        let failure = LoginItemLogic.change(to: true, using: loginItem)
        #expect(failure == "Couldn't turn on Open at login: Operation not permitted")
        let view = SettingsRenderFrame {
            GeneralSettingsView(loginFailure: failure)
                .environment(DemoFixtures.controller(.off, configuration: configuration))
                .environment(\.loginItem, loginItem)
                .environment(\.callDetectionSupported, false)
        }
        try RenderHarness.render(
            view, size: CGSize(width: 580, height: 540), name: "settings-general-notes" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("Rules renders three rules with one open and a matching sentence", arguments: [false, true])
    func rules(dark: Bool) throws {
        let view = SettingsRenderFrame {
            SettingsView(section: .rules)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
                .environment(\.matchTesterSeed, "okay so before we wrap up, can Bala share the screen")
        }
        try RenderHarness.render(
            view, size: settingsSize, name: "settings-rules" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("The whole Rules editor, taller than the window, has no clipped text", arguments: [false, true])
    func rulesEditorInFull(dark: Bool) throws {
        let view = SettingsRenderFrame {
            SettingsView(section: .rules)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
                .environment(\.matchTesterSeed, "we talked to Bhala and Kumar about it")
        }
        try RenderHarness.render(
            view, size: CGSize(width: 760, height: 980), name: "settings-rules-full" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("Rules with long words, an unnamed rule and no match renders")
    func rulesLongText() throws {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.rules = [
            Rule(
                name: "A rule with a very long name that goes on and on and on",
                terms: ["Bala", "Balakumar", "Bala Kumar", "Chidambaram Venkatasubramanian", "Sriram", "Sai Ram", "Aman"],
                channels: [.sound, .notification, .ntfy, .webhook]),
            Rule(name: " ", terms: []),
        ]
        let view = SettingsRenderFrame {
            SettingsView(section: .rules)
                .environment(DemoFixtures.controller(.off, configuration: configuration))
                .environment(\.matchTesterSeed, "nothing like that was said")
        }
        try RenderHarness.render(view, size: settingsSize, name: "settings-rules-long")
    }

    @Test("A channel that is on but no longer set up stays a box that can be unchecked", arguments: [false, true])
    func rulesChannelThatWasSetUp(dark: Bool) throws {
        var configuration = DemoFixtures.settingsConfiguration
        // ntfy and the webhook are on for the first rule, and neither has an address any more.
        configuration.rules[0].channels = [.sound, .notification, .ntfy, .webhook]
        #expect(!configuration.channels.isConfigured(.ntfy))
        #expect(!configuration.channels.isConfigured(.webhook))
        let view = SettingsRenderFrame {
            SettingsView(section: .rules)
                .environment(DemoFixtures.controller(.off, configuration: configuration))
        }
        try RenderHarness.render(
            view, size: CGSize(width: 760, height: 980), name: "settings-rules-unconfigured-checked" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("Rules with no rules renders its empty state")
    func rulesEmpty() throws {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.rules = []
        let view = SettingsRenderFrame {
            SettingsView(section: .rules)
                .environment(DemoFixtures.controller(.off, configuration: configuration))
        }
        try RenderHarness.render(view, size: settingsSize, name: "settings-rules-empty")
    }
}

/// Shows Settings as the open window is drawn: as the key window, on the window background.
struct SettingsRenderFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A login item that does what it is told, for renders and tests.
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status
    var registrationError: (any Error)?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        if let registrationError { throw registrationError }
        status = .notRegistered
    }

    func openSystemSettings() {}
}

@Suite("Settings copy and logic")
@MainActor
struct SettingsLogicTests {
    @Test("The sidebar lists the seven panes with symbols that exist")
    func sections() {
        #expect(SettingsSection.allCases.map(\.title) == [
            "General", "Rules", "Alerts", "Speech", "History", "Shortcuts & API", "About",
        ])
        #expect(SettingsSection.allCases.map(\.systemImage) == [
            "gearshape", "text.badge.checkmark", "bell", "waveform", "clock", "curlybraces", "info.circle",
        ])
        for section in SettingsSection.allCases {
            #expect(NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil) != nil)
        }
    }

    @Test("Channels have the names the settings use")
    func channelNames() {
        #expect(ChannelKind.allCases.map(\.displayName) == [
            "Sound", "Notification", "Alarm until dismissed", "Screen flash", "ntfy push", "Telegram call", "Webhook",
        ])
    }

    @Test("General words the options as the spec does")
    func generalWords() {
        #expect(AudioSourceKind.allCases.map(GeneralSettingsView.title(for:)) == ["System audio", "Microphone", "Both"])
        #expect(ListeningMode.allCases.map(GeneralSettingsView.title(for:)) == ["Always", "Only during calls"])
        #expect(GeneralSettingsView.explanation(for: .always, callDetectionSupported: false) == "Needs macOS 14.2 or later")
        #expect(GeneralSettingsView.explanation(for: .duringCalls, callDetectionSupported: false)
            == "Needs macOS 14.2 or later")
        #expect(GeneralSettingsView.explanation(for: .duringCalls, callDetectionSupported: true)
            .contains("microphone"))
        for source in AudioSourceKind.allCases {
            #expect(!GeneralSettingsView.explanation(for: source).isEmpty)
        }
    }

    @Test("Sensitivity is explained with the exact words")
    func sensitivityWords() {
        #expect(Sensitivity.allCases.map(RuleEditorView.title(for:)) == ["Exact", "Balanced", "Loose"])
        #expect(RuleEditorView.explanation(for: .exact) == "Exact: only the exact word.")
        #expect(RuleEditorView.explanation(for: .balanced)
            == "Balanced: allows small mishearings like Bhala for Bala.")
        #expect(RuleEditorView.explanation(for: .loose) == "Loose: catches more, may alert on similar words.")
    }

    @Test("The login item shows on, off and waiting, and says why it failed")
    func loginItem() {
        #expect(LoginItemLogic.isOn(.enabled))
        #expect(LoginItemLogic.isOn(.requiresApproval))
        #expect(!LoginItemLogic.isOn(.notRegistered))
        #expect(!LoginItemLogic.isOn(.notFound))
        #expect(LoginItemLogic.needsApproval(.requiresApproval))
        #expect(!LoginItemLogic.needsApproval(.enabled))

        let item = FakeLoginItem(status: .notRegistered)
        #expect(LoginItemLogic.change(to: true, using: item) == nil)
        #expect(item.status == .enabled)
        #expect(LoginItemLogic.change(to: false, using: item) == nil)
        #expect(item.status == .notRegistered)

        item.registrationError = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nope"])
        #expect(LoginItemLogic.change(to: true, using: item) == "Couldn't turn on Open at login: Nope")
        #expect(LoginItemLogic.change(to: false, using: item) == "Couldn't turn off Open at login: Nope")
    }

    @Test("The cooldown steps finely when short and coarsely when long, and stays within 2 to 600")
    func cooldownSteps() {
        let upward: [(Double, Double)] = [
            (2, 3), (9, 10), (10, 15), (12, 15), (25, 30), (30, 45), (119, 120), (120, 150), (299, 300), (300, 360),
            (599, 600), (600, 600),
        ]
        for (from, to) in upward {
            #expect(CooldownSteps.increased(from) == to, "up from \(from)")
        }
        let downward: [(Double, Double)] = [
            (600, 540), (360, 300), (300, 270), (150, 120), (120, 105), (45, 30), (30, 25), (15, 10), (12, 10),
            (10, 9), (3, 2), (2, 2),
        ]
        for (from, to) in downward {
            #expect(CooldownSteps.decreased(from) == to, "down from \(from)")
        }
        // Up and down from the range's ends never leaves it.
        #expect(CooldownSteps.increased(Rule.cooldownRange.upperBound) == Rule.cooldownRange.upperBound)
        #expect(CooldownSteps.decreased(Rule.cooldownRange.lowerBound) == Rule.cooldownRange.lowerBound)
        // Walking all the way up takes about twenty presses.
        var presses = 0
        var seconds = Rule.cooldownRange.lowerBound
        while seconds < Rule.cooldownRange.upperBound {
            seconds = CooldownSteps.increased(seconds)
            presses += 1
        }
        #expect(presses < 40)
    }

    @Test("Durations read short")
    func durations() {
        #expect(DurationText.short(0) == "0 s")
        #expect(DurationText.short(3) == "3 s")
        #expect(DurationText.short(60) == "1 min")
        #expect(DurationText.short(90) == "1 min 30 s")
        #expect(DurationText.short(600) == "10 min")
        #expect(DurationText.spoken(10).contains("10"))
    }

    @Test("Typed words are split at commas, trimmed, and not repeated")
    func typedWords() {
        #expect(TermChipsField.terms(from: "Bala", besides: []) == ["Bala"])
        #expect(TermChipsField.terms(from: " Bala ,  Kumar   Sharma ,, kumar sharma , ", besides: ["BALA"])
            == ["Kumar Sharma"])
        #expect(TermChipsField.terms(from: "   ", besides: []).isEmpty)
        #expect(TermChipsField.terms(from: ",", besides: []).isEmpty)

        var rule = Rule(name: "x", terms: ["Bala"])
        rule.addTerms(["bala", "Kumar", "kumar", "Sriram"])
        #expect(rule.terms == ["Bala", "Kumar", "Sriram"])
    }

    @Test("The rule list names a rule and summarizes its words")
    func ruleRows() {
        let rule = Rule(name: "My name", terms: ["Bala", " Balakumar ", "  "])
        #expect(RuleRow.title(of: rule) == "My name")
        #expect(RuleRow.summary(of: rule) == "Bala, Balakumar")
        #expect(RuleRow.title(of: Rule(name: "  ", terms: [])) == "Untitled rule")
        #expect(RuleRow.summary(of: Rule(name: "x", terms: [])) == "No words yet")
    }

    @Test("The tester says what the rule would do with a sentence, and marks the matched words")
    func tester() throws {
        let rule = Rule(name: "My name", terms: ["Bala"])
        #expect(MatchTesterView.outcome(of: "  ", rule: rule) == .empty)
        #expect(MatchTesterView.outcome(of: "hello", rule: Rule(name: "x", terms: [])) == .noWords)
        #expect(MatchTesterView.outcome(of: "hello", rule: Rule(name: "x", terms: ["  "])) == .noWords)
        #expect(MatchTesterView.outcome(of: "nothing like that was said", rule: rule) == .noMatch)

        let sentence = "can Bala share the screen, and Bala again"
        guard case .matches(let marked, let count) = MatchTesterView.outcome(of: sentence, rule: rule) else {
            Issue.record("Expected a match")
            return
        }
        #expect(count == 2)
        #expect(String(marked.characters) == sentence)
        #expect(MatchTesterView.markedParts(of: marked) == ["Bala", "Bala"])

        // The mark lands on the words as spoken, not on the rule's word.
        let loose = Rule(name: "x", terms: ["Balakumar"])
        guard case .matches(let split, _) = MatchTesterView.outcome(of: "hi Bala Kumar there", rule: loose) else {
            Issue.record("Expected Balakumar to match Bala Kumar")
            return
        }
        #expect(MatchTesterView.markedParts(of: split) == ["Bala Kumar"])
    }

    @Test("Changes made one after another land in order, on the latest configuration")
    func orderedEdits() async {
        let controller = DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration)
        let id = controller.configuration.rules[0].id
        controller.edit(rule: id) { $0.name = "A" }
        controller.edit(rule: id) { $0.name = "AB" }
        controller.edit(rule: id) { $0.addTerms(["Kumar"]) }
        controller.edit(rule: id) { $0.addTerms(["kumar"]) }
        controller.edit(rule: UUID()) { $0.name = "nobody" }
        controller.edit { $0.globalCooldownSeconds = 99 }  // clamped to 30
        await controller.finishPendingEdits()
        let rule = controller.configuration.rules[0]
        #expect(rule.name == "AB")
        #expect(rule.terms.filter { $0.lowercased() == "kumar" }.count == 1)
        #expect(controller.configuration.rules.map(\.name).contains("nobody") == false)
        #expect(controller.configuration.globalCooldownSeconds == 30)
    }

    @Test("A binding shows the configuration and writes through the controller")
    func bindings() async {
        let controller = DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration)
        let source = controller.binding(\.listening.source)
        #expect(source.wrappedValue == .systemAudio)
        source.wrappedValue = .microphone
        await controller.finishPendingEdits()
        #expect(source.wrappedValue == .microphone)
        #expect(controller.configuration.listening.source == .microphone)
    }
}

// MARK: - Alerts and Speech renders

extension SettingsRenderTests {
    @Test("Alerts renders from its top and from its bottom, and whole", arguments: [false, true])
    func alerts(dark: Bool) async throws {
        let configuration = SettingsFixtures.alertsConfiguration
        let controller = await SettingsFixtures.controller(
            configuration: configuration, notifications: .notDetermined,
            failingChannels: [
                .ntfy: HTTPError.status(404),
                .webhook: URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."]),
            ])
        let secrets = SecretsModel(
            store: InMemorySecretStore([
                SecretAccount.ntfyToken: "token", SecretAccount.webhookHeader("X-Api-Key"): "key",
            ]))
        secrets.refresh(AlertsSettingsView.secretAccounts(for: configuration.channels))
        // The channels that failed have said so.
        let recorded = await controller.lastDeliveryFailures()
        #expect(recorded[.ntfy]?.reason == "HTTP 404")
        #expect(recorded[.webhook]?.reason == "The request timed out.")
        let view = SettingsRenderFrame {
            SettingsView(section: .alerts)
                .environment(controller)
                .environment(secrets)
        }
        let suffix = dark ? "-dark" : ""
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        try await RenderHarness.render(
            view, size: settingsSize, name: "settings-alerts-top" + suffix, appearance: appearance,
            afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: settingsSize, name: "settings-alerts-bottom" + suffix, appearance: appearance,
            scrollsToEnd: true, afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: CGSize(width: 760, height: 1800), name: "settings-alerts-full" + suffix,
            appearance: appearance, afterWaiting: settleTime)
    }

    @Test("Speech renders with one model installed and one downloading", arguments: [false, true])
    func speech(dark: Bool) async throws {
        let controller = await SettingsFixtures.controller(
            installedModels: [.lightEnglish, .vad], stalledDownloads: [.balancedEnglish: 0.3])
        let capabilities = SettingsFixtures.capabilities
        let view = SettingsRenderFrame {
            SettingsView(section: .speech)
                .environment(controller)
                .environment(\.speechCapabilities, { capabilities })
        }
        let suffix = dark ? "-dark" : ""
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        try await RenderHarness.render(
            view, size: settingsSize, name: "settings-speech" + suffix, appearance: appearance,
            afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: settingsSize, name: "settings-speech-bottom" + suffix, appearance: appearance,
            scrollsToEnd: true, afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: CGSize(width: 760, height: 1000), name: "settings-speech-full" + suffix,
            appearance: appearance, afterWaiting: settleTime)
    }

    @Test("Speech renders the local model chosen, in another language, and with no engine to use")
    func speechVariants() async throws {
        var local = DemoFixtures.settingsConfiguration
        local.speech.engine = .localModel
        local.speech.localModelSize = .balanced
        local.speech.localeIdentifier = "de-DE"
        let localController = await SettingsFixtures.controller(
            configuration: local, installedModels: [.balancedMultilingual, .lightEnglish])
        let capabilities = SettingsFixtures.capabilities
        try await RenderHarness.render(
            SettingsRenderFrame {
                SettingsView(section: .speech)
                    .environment(localController)
                    .environment(\.speechCapabilities, { capabilities })
            }, size: CGSize(width: 760, height: 1000), name: "settings-speech-local", afterWaiting: settleTime)

        var appleOnly = DemoFixtures.settingsConfiguration
        appleOnly.speech.engine = .apple
        let noApple = SettingsFixtures.capabilitiesWithoutApple
        let unavailableController = await SettingsFixtures.controller(
            configuration: appleOnly, capabilities: noApple)
        try await RenderHarness.render(
            SettingsRenderFrame {
                SettingsView(section: .speech)
                    .environment(unavailableController)
                    .environment(\.speechCapabilities, { noApple })
            }, size: settingsSize, name: "settings-speech-unavailable", afterWaiting: settleTime)
    }

    @Test("A model row renders in every state, with its notes", arguments: [false, true])
    func modelRows(dark: Bool) throws {
        try RenderHarness.render(
            SettingsRenderFrame { ModelRowsSheet() }, size: CGSize(width: 580, height: 640),
            name: "settings-model-rows" + (dark ? "-dark" : ""), appearance: dark ? .darkAqua : .aqua)
    }
}

/// Model rows in each state, as the Models section lists them.
private struct ModelRowsSheet: View {
    var body: some View {
        Form {
            Section {
                row(.lightEnglish, .installed(inUse: true))
                row(.lightMultilingual, .installed(inUse: false))
                row(.balancedEnglish, .downloading(0.3))
                row(.balancedMultilingual, .notInstalled)
                row(
                    .balancedMultilingual, .notInstalled,
                    message: ModelActions.message(for: ModelError.insufficientSpace(required: 119_414_000, available: 80_100_000)))
                row(
                    .lightEnglish, .installed(inUse: false),
                    message: ModelActions.message(for: ListeningControllerError.modelInUse))
            } header: {
                SettingsSectionTitle("Models")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ model: WhisperModel, _ state: ModelRowState, message: String? = nil) -> some View {
        ModelRow(model: model, state: state, message: message, download: {}, cancel: {}, delete: {})
    }
}

// MARK: - Alerts and Speech logic

@Suite("Alerts and Speech logic")
@MainActor
struct AlertsAndSpeechLogicTests {
    private struct RefusingStore: SecretStore {
        func secret(for account: String) -> String? { nil }
        func setSecret(_ value: String?, for account: String) throws { throw KeychainError(status: -25308) }
    }

    /// Waits until `condition` holds, for at most three seconds.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Gave up waiting until \(what)")
    }

    // MARK: Secrets

    @Test("A typed secret is saved without the spaces around it, and shown only as Saved")
    func secretsAreSaved() {
        let store = InMemorySecretStore()
        let secrets = SecretsModel(store: store)
        #expect(!secrets.isSaved("a"))

        secrets.drafts["a"] = "  tok-123\n"
        secrets.commit("a")
        #expect(store.secret(for: "a") == "tok-123")
        #expect(secrets.isSaved("a"))
        #expect(secrets.drafts["a"] == nil)

        // Typing nothing leaves the secret as it is.
        secrets.drafts["a"] = "   "
        secrets.commit("a")
        #expect(store.secret(for: "a") == "tok-123")
        #expect(secrets.drafts["a"] == nil)

        // A new value replaces it.
        secrets.drafts["a"] = "new"
        secrets.commit("a")
        #expect(store.secret(for: "a") == "new")

        secrets.clear("a")
        #expect(store.secret(for: "a") == nil)
        #expect(!secrets.isSaved("a"))
    }

    @Test("Refreshing finds which secrets exist, and Test saves everything typed")
    func secretsRefreshAndCommitAll() {
        let store = InMemorySecretStore(["x": "1"])
        let secrets = SecretsModel(store: store)
        secrets.refresh(["x", "y"])
        #expect(secrets.isSaved("x"))
        #expect(!secrets.isSaved("y"))

        secrets.drafts["y"] = "2"
        secrets.drafts["z"] = "3"
        secrets.commitAll()
        #expect(store.secret(for: "y") == "2" && store.secret(for: "z") == "3")
        #expect(secrets.drafts.isEmpty)
        #expect(secrets.isSaved("y") && secrets.isSaved("z"))
    }

    @Test("A Keychain that refuses keeps what was typed and says so, without the secret")
    func secretsRefused() {
        let secrets = SecretsModel(store: RefusingStore())
        secrets.drafts["a"] = "super-secret-value"
        secrets.commit("a")
        #expect(!secrets.isSaved("a"))
        #expect(secrets.drafts["a"] == "super-secret-value")
        let error = secrets.errors["a"] ?? ""
        #expect(error.hasPrefix("Couldn't save to the Keychain."))
        #expect(!error.contains("super-secret-value"))
    }

    @Test("The Alerts settings keep three kinds of secret, one per header")
    func secretAccounts() {
        var channels = ChannelSettings()
        channels.webhook.headerNames = ["X-Api-Key"]
        #expect(AlertsSettingsView.secretAccounts(for: channels) == [
            "ntfy.token", "webhook.signingSecret", "webhook.header.X-Api-Key",
        ])
    }

    // MARK: Channels

    @Test("An address is judged by the channel's own rule, and the note says what to change")
    func addressNotes() {
        #expect(AddressCheck.message(for: "") == nil)
        #expect(AddressCheck.message(for: "  ") == nil)
        #expect(AddressCheck.message(for: "https://ntfy.sh") == nil)
        #expect(AddressCheck.message(for: "http://192.168.1.20:8080/hook") == nil)
        #expect(AddressCheck.message(for: "http://nas.local/hook") == nil)
        #expect(AddressCheck.message(for: "http://example.com/hook") == "Use https (http works only on your local network).")
        #expect(AddressCheck.message(for: "HTTP://example.com") == AddressCheck.httpsHint)
        #expect(AddressCheck.message(for: "ntfy.sh") == AddressCheck.incompleteHint)
        #expect(AddressCheck.message(for: "ftp://example.com") == AddressCheck.incompleteHint)
        #expect(AddressCheck.isUsable("https://example.com"))
        #expect(!AddressCheck.isUsable("http://example.com"))
    }

    @Test("A channel that is not set up cannot be turned on, but one that is on can always be turned off")
    func channelCheckboxes() {
        #expect(!RuleEditorView.isChannelDisabled(isConfigured: true, isChecked: false))
        #expect(!RuleEditorView.isChannelDisabled(isConfigured: true, isChecked: true))
        #expect(RuleEditorView.isChannelDisabled(isConfigured: false, isChecked: false))
        // Its address was cleared after it was checked: the box stays usable, so that it can be unchecked.
        #expect(!RuleEditorView.isChannelDisabled(isConfigured: false, isChecked: true))
    }

    @Test("A header name has no spaces or colons, and is not added twice")
    func headerNames() {
        #expect(HeaderName.isValid("X-Api-Key"))
        #expect(HeaderName.isValid("Authorization"))
        #expect(!HeaderName.isValid("X Api"))
        #expect(!HeaderName.isValid("X:Api"))
        #expect(!HeaderName.isValid("Név"))
        #expect(!HeaderName.isValid(""))
        #expect(HeaderName.message(for: "", existing: []) == nil)
        #expect(HeaderName.message(for: "X-Team", existing: ["X-Api-Key"]) == nil)
        #expect(HeaderName.message(for: "x-api-key", existing: ["X-Api-Key"]) == HeaderName.duplicateMessage)
        #expect(HeaderName.message(for: "X Api", existing: []) == HeaderName.invalidMessage)
    }

    @Test("A test cannot be sent until the channel is set up, nor a notification until they are allowed")
    func testsAreBlocked() {
        var channels = ChannelSettings()
        let settingsNote = "Fill in the settings above to test."
        for kind in [ChannelKind.sound, .persistentAlarm, .screenFlash] {
            #expect(ChannelTestRow.blockedReason(for: kind, channels: channels, notifications: .granted) == nil)
        }
        #expect(ChannelTestRow.blockedReason(for: .ntfy, channels: channels, notifications: .granted) == settingsNote)
        #expect(ChannelTestRow.blockedReason(for: .telegramCall, channels: channels, notifications: .granted) == settingsNote)
        #expect(ChannelTestRow.blockedReason(for: .webhook, channels: channels, notifications: .granted) == settingsNote)
        channels.ntfy.topic = "my-topic"
        channels.telegramCall.user = "@me"
        channels.webhook.url = "https://example.com/hook"
        for kind in [ChannelKind.ntfy, .telegramCall, .webhook] {
            #expect(ChannelTestRow.blockedReason(for: kind, channels: channels, notifications: .granted) == nil)
        }
        #expect(ChannelTestRow.blockedReason(for: .notification, channels: channels, notifications: .notDetermined)
            == "Turn on notifications first.")
        #expect(ChannelTestRow.blockedReason(for: .notification, channels: channels, notifications: .denied)
            == "Turn on notifications first.")
        #expect(ChannelTestRow.blockedReason(for: .notification, channels: channels, notifications: .granted) == nil)
    }

    @Test("A failed delivery is worded as the dispatcher words it, and said once")
    func failureLines() {
        #expect(ChannelTestRow.reason(for: HTTPError.status(500)) == "HTTP 500")
        #expect(ChannelTestRow.reason(for: URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
        #expect(ChannelTestRow.reason(for: AlertDeliveryError.notConfigured(.ntfy)) == "Not set up yet")

        let now = DemoFixtures.today(11, 0)
        let failure = DeliveryFailure(kind: .ntfy, reason: "HTTP 404", date: DemoFixtures.today(10, 32))
        let line = ChannelTestRow.lastFailureLine(failure, phase: .idle, now: now)
        #expect(line == "Last delivery failed: HTTP 404 (\(DemoFixtures.today(10, 32).formatted(date: .omitted, time: .shortened)))")
        #expect(ChannelTestRow.lastFailureLine(failure, phase: .sent, now: now) == line)
        // The test that just failed said the same thing: no second line for it.
        #expect(ChannelTestRow.lastFailureLine(failure, phase: .failed("HTTP 404"), now: now) == nil)
        #expect(ChannelTestRow.lastFailureLine(failure, phase: .failed("HTTP 500"), now: now) == line)
        #expect(ChannelTestRow.lastFailureLine(nil, phase: .idle, now: now) == nil)
    }

    @Test("Each channel that sends words off the Mac says so, and to whom")
    func leavesTheMacNotes() {
        // ntfy's message is the words around the mention (the excerpt only stands in when there are none), and the
        // call's message has no placeholder for the excerpt: neither sends the seconds before.
        #expect(LeavesTheMacNote.ntfy == "Sends the words around the mention to ntfy.")
        #expect(LeavesTheMacNote.telegramCall == "Sends the words around the mention to CallMeBot.")
        // The webhook's JSON carries the excerpt, the last 30 seconds up to the mention, next to the words around it.
        #expect(
            LeavesTheMacNote.webhook
                == "Sends the words around the mention, plus up to 30 seconds before it, to your webhook.")
    }

    @Test("The notifications row asks once, then points to System Settings, like the popover's note")
    func notificationRowOffer() throws {
        try withScratchAsks { asks in
            #expect(NotificationPermissionRow.offer(for: .notDetermined, asks: asks) == .allow)
            // Never asked, but already refused (in System Settings, or by an earlier install): no question to ask.
            #expect(NotificationPermissionRow.offer(for: .denied, asks: asks) == .openSystemSettings)
        }
        // Asked for, and still not allowed: the system will not ask again.
        try withScratchAsks(asked: [.notifications]) { asks in
            #expect(NotificationPermissionRow.offer(for: .notDetermined, asks: asks) == .openSystemSettings)
            #expect(NotificationPermissionRow.offer(for: .denied, asks: asks) == .openSystemSettings)
        }
        // What was asked for is per permission: Screen Recording being asked for says nothing about notifications.
        try withScratchAsks(asked: [.screenRecording]) { asks in
            #expect(NotificationPermissionRow.offer(for: .notDetermined, asks: asks) == .allow)
        }
    }

    @Test("A sound menu offers every system sound, and one that is in use but not among them")
    func soundChoices() {
        #expect(SoundChoices.names(including: "Glass") == SystemSounds.names)
        #expect(SoundChoices.names(including: "Custom") == SystemSounds.names + ["Custom"])
        #expect(NtfySection.title(for: .default) == "Default")
        #expect(NtfySection.title(for: .high) == "High")
        #expect(NtfySection.title(for: .urgent) == "Urgent")
        #expect(TelegramSection.placeholderNote == "{keyword}, {text} and {context} are replaced")
    }

    // MARK: Models

    @Test("Models are named and sized for the list")
    func modelWords() {
        #expect(SpeechSettingsView.models.map(ModelRow.name(for:)) == [
            "Light · English", "Light · Multilingual", "Balanced · English", "Balanced · Multilingual",
        ])
        #expect(SpeechSettingsView.models.map(ModelRow.size(of:)) == ["32 MB", "32 MB", "60 MB", "60 MB"])
        #expect(ModelRow.size(of: .vad) == "1 MB")
        #expect(ModelRow.detail(for: .lightEnglish, state: .notInstalled) == "32 MB")
        #expect(ModelRow.detail(for: .lightEnglish, state: .installed(inUse: false)) == "32 MB")
        #expect(ModelRow.detail(for: .lightEnglish, state: .installed(inUse: true)) == "32 MB · In use")
    }

    @Test("A model is installed, downloading or neither, and in use only while listening on it")
    func modelStates() {
        let installed: Set<WhisperModel> = [.lightEnglish, .balancedEnglish]
        let downloads: [WhisperModel: Double] = [.balancedEnglish: 0.3, .lightMultilingual: 0]
        #expect(ModelRowState.of(.lightEnglish, installed: installed, downloads: downloads, inUse: .lightEnglish)
            == .installed(inUse: true))
        #expect(ModelRowState.of(.lightEnglish, installed: installed, downloads: downloads, inUse: nil)
            == .installed(inUse: false))
        #expect(ModelRowState.of(.balancedEnglish, installed: installed, downloads: downloads, inUse: nil)
            == .downloading(0.3))
        #expect(ModelRowState.of(.lightMultilingual, installed: installed, downloads: downloads, inUse: nil)
            == .downloading(0))
        #expect(ModelRowState.of(.balancedMultilingual, installed: installed, downloads: downloads, inUse: nil)
            == .notInstalled)

        func listening(_ engine: EngineID, _ locale: String) -> ListeningState {
            .listening(ListeningInfo(engine: engine, source: .systemAudio, localeIdentifier: locale))
        }
        #expect(ModelRowState.modelInUse(by: listening(.whisperBalanced, "en-US")) == .balancedEnglish)
        #expect(ModelRowState.modelInUse(by: listening(.whisperLight, "de-DE")) == .lightMultilingual)
        #expect(ModelRowState.modelInUse(by: listening(.appleSpeechTranscriber, "en-US")) == nil)
        #expect(ModelRowState.modelInUse(by: .off) == nil)
        #expect(ModelRowState.modelInUse(by: .preparing(.starting)) == nil)
    }

    @Test("A failed download or delete says what to do")
    func modelMessages() {
        #expect(ModelActions.message(for: ListeningControllerError.modelInUse)
            == "This model is in use. Pause listening or pick another model before deleting it.")
        #expect(ModelActions.message(for: ModelError.checksumMismatch)
            == "The download was damaged and was removed. Try again.")
        #expect(ModelActions.message(for: ModelError.sizeMismatch(expected: 2, actual: 1))
            == "The download was damaged and was removed. Try again.")
        #expect(ModelActions.message(for: ModelError.httpStatus(503))
            == "The download server answered with HTTP 503. Try again later.")
        let space = ModelActions.message(for: ModelError.insufficientSpace(required: 120_000_000, available: 80_000_000))
        #expect(space.hasPrefix("Not enough free space: it needs ") && space.contains("MB"))
        #expect(ModelActions.message(for: URLError(.notConnectedToInternet))
            == URLError(.notConnectedToInternet).localizedDescription)
    }

    @Test("A download started here is cancelled here, and a model that is not in use can be deleted")
    func modelActions() async {
        let controller = await SettingsFixtures.controller(
            installedModels: [.lightEnglish], stalledDownloads: [.balancedEnglish: 0.3], startsStalledDownloads: false)
        #expect(controller.installedModels.contains(.lightEnglish))
        let actions = ModelActions()

        actions.download(.balancedEnglish, using: controller)
        await waitUntil("the download shows its progress") { controller.modelDownloads[.balancedEnglish] == 0.3 }
        actions.cancel(.balancedEnglish, using: controller)
        await waitUntil("the cancelled download is gone") { controller.modelDownloads[.balancedEnglish] == nil }
        #expect(actions.messages[.balancedEnglish] == nil)

        actions.delete(.lightEnglish, using: controller)
        await waitUntil("the model is deleted") { !controller.installedModels.contains(.lightEnglish) }
        #expect(actions.messages[.lightEnglish] == nil)
    }

    // MARK: Speech

    @Test("The engines are named, explained and summed up in plain words")
    func engineWords() {
        #expect(EnginePreference.allCases.map(SpeechSettingsView.title(for:)) == ["Automatic", "Apple only", "Local model"])
        for preference in EnginePreference.allCases {
            #expect(!SpeechSettingsView.explanation(for: preference).isEmpty)
        }
        #expect(LocalModelSize.allCases.map(SpeechSettingsView.title(for:)) == ["Light", "Balanced"])
        #expect(SpeechSettingsView.memoryText(for: .light) == "≈170 MB memory")
        #expect(SpeechSettingsView.memoryText(for: .balanced) == "≈260 MB memory")

        let english = SpeechLanguages.title(for: "en-US")
        let apple = SpeechSettingsView.summary(
            for: .engine(.appleSpeechTranscriber, localeIdentifier: "en-US"), preference: .automatic)
        #expect(apple == .init(name: "Apple Speech (on-device)", reason: "Apple speech supports \(english) on this Mac."))
        let fallback = SpeechSettingsView.summary(
            for: .engine(.whisperLight, localeIdentifier: "en-US"), preference: .automatic)
        #expect(fallback.name == "Local model · Light")
        #expect(fallback.reason == "Apple speech can't do \(english) on this Mac, so the local model is used.")
        #expect(SpeechSettingsView.summary(for: .engine(.whisperBalanced, localeIdentifier: "en-US"), preference: .localModel)
            .reason == "You chose the local model. Language: \(english).")
        #expect(SpeechSettingsView.summary(for: .engine(.appleSFSpeech, localeIdentifier: "en-US"), preference: .apple)
            .reason == "You chose Apple only. Language: \(english).")
        let none = SpeechSettingsView.summary(for: .unavailable(reason: "Nothing for X."), preference: .apple)
        #expect(none.isProblem && none.reason == "Nothing for X. Try Automatic or Local model.")
        #expect(SpeechSettingsView.summary(for: nil, preference: .automatic).name == "Checking…")
    }

    @Test("The Language menu lists what the engine in use understands")
    func languageLists() {
        let capabilities = SettingsFixtures.capabilities
        #expect(SpeechLanguages.whisperCodes.count == 99)
        #expect(Set(SpeechLanguages.whisperCodes).count == 99)

        let transcriber = SpeechLanguages.identifiers(
            for: .engine(.appleSpeechTranscriber, localeIdentifier: "en-US"), capabilities: capabilities, selected: nil)
        #expect(Set(transcriber) == Set(capabilities.speechTranscriberLocales))
        let titles = transcriber.map(SpeechLanguages.title(for:))
        #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        let sf = SpeechLanguages.identifiers(
            for: .engine(.appleSFSpeech, localeIdentifier: "en-US"), capabilities: capabilities, selected: nil)
        #expect(Set(sf) == ["en-US", "de-DE"])

        let local = SpeechLanguages.identifiers(
            for: .engine(.whisperLight, localeIdentifier: "en-US"), capabilities: capabilities, selected: nil)
        #expect(Set(local) == Set(SpeechLanguages.whisperCodes))

        // The chosen language is always in the list, even when this engine does not know it.
        let chosen = SpeechLanguages.identifiers(
            for: .engine(.appleSFSpeech, localeIdentifier: "en-US"), capabilities: capabilities, selected: "xx-XX")
        #expect(chosen.contains("xx-XX"))

        // With no engine to use, or while it is not known yet: what Apple's engines know.
        let all = SpeechLanguages.identifiers(
            for: .unavailable(reason: "x"), capabilities: capabilities, selected: nil)
        #expect(Set(all) == Set(capabilities.speechTranscriberLocales))
        #expect(SpeechLanguages.identifiers(for: nil, capabilities: nil, selected: nil).isEmpty)
        #expect(SpeechLanguages.identifiers(for: nil, capabilities: nil, selected: "fr-FR") == ["fr-FR"])
        #expect(SpeechLanguages.systemDefaultTitle.hasPrefix("System default"))
    }

    @Test("A language is named without the region override some Macs add")
    func languageTitles() {
        let plain = SpeechLanguages.title(for: "en_US")
        #expect(!plain.isEmpty)
        #expect(plain == (Locale.current.localizedString(forIdentifier: "en_US") ?? "en_US"))
        #expect(SpeechLanguages.title(for: "en_US@rg=inzzzz") == plain)
        #expect(SpeechLanguages.title(for: "xx") == (Locale.current.localizedString(forIdentifier: "xx") ?? "xx"))
    }

    @Test("Settings opens on the pane it was left on, and on General when there is none")
    func lastPane() throws {
        let name = "namealert-settings-test-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        #expect(SettingsView.lastSection(in: suite) == .general)
        suite.set("alerts", forKey: SettingsView.lastSectionKey)
        #expect(SettingsView.lastSection(in: suite) == .alerts)
        suite.set("nonsense", forKey: SettingsView.lastSectionKey)
        #expect(SettingsView.lastSection(in: suite) == .general)
    }
}
