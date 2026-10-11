import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import ServiceManagement
import SwiftUI
import Testing

@testable import ScreenshotHost

/// The Settings window at its minimum size, 760 × 540 points.
private let settingsSize = CGSize(width: 760, height: 540)

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
