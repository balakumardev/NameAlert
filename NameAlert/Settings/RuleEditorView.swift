import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// The chosen rule, open for editing: its name and words, how forgiving the matching is, a place to try a sentence,
/// how to be alerted, and how long to wait before alerting again.
struct RuleEditorView: View {
    let ruleID: Rule.ID
    /// Puts the keyboard in the words field when the editor opens (a rule that was just added).
    var focusesWords = false

    @Environment(ListeningController.self) private var controller
    @Environment(\.settingsNavigation) private var navigation
    @Environment(\.matchTesterSeed) private var testerSeed
    @Environment(\.proUpsell) private var upsell
    @FocusState private var isWordsFocused: Bool

    var body: some View {
        if let rule = controller.configuration.rules.first(where: { $0.id == ruleID }) {
            Form {
                if controller.proPolicy.heldBackRuleIDs(in: controller.configuration.rules).contains(rule.id) {
                    Section {
                        NoticeRow(systemImage: "lock.fill", tint: .accentColor, message: ProCopy.ruleHeldBack) {
                            Button(ProCopy.unlockTitle) { upsell.show(.ruleLimit) }
                                .accessibilityLabel("Unlock Pro for more rules")
                        }
                    }
                }
                ruleSection(rule)

                Section {
                    MatchTesterView(rule: rule, initialSentence: testerSeed)
                } header: {
                    SettingsSectionTitle("Try a sentence")
                }

                Section {
                    ForEach(ChannelKind.allCases, id: \.self) { kind in
                        channelRow(kind, in: rule)
                    }
                } header: {
                    SettingsSectionTitle("Alert with")
                }

                Section {
                    cooldownRow(rule)
                } header: {
                    SettingsSectionTitle("Cooldown")
                }
            }
            .formStyle(.grouped)
            .task {
                // The field is not there to take the keyboard until the form has been built.
                guard focusesWords else { return }
                try? await Task.sleep(for: .milliseconds(150))
                isWordsFocused = true
            }
        } else {
            ContentUnavailableView("No rule chosen", systemImage: "text.badge.checkmark")
        }
    }

    // MARK: Name, words, sensitivity

    private func ruleSection(_ rule: Rule) -> some View {
        Section {
            LabeledTextField(title: "Name", value: rule.name, prompt: "Rule name") { name in
                controller.edit(rule: ruleID) { $0.name = name }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Listen for")
                TermChipsField(
                    terms: rule.terms, focus: $isWordsFocused,
                    add: { new in controller.edit(rule: ruleID) { $0.addTerms(new) } },
                    remove: { term in
                        controller.edit(rule: ruleID) { rule in
                            if let index = rule.terms.firstIndex(of: term) { rule.terms.remove(at: index) }
                        }
                    })
                SettingsCaption("Press Return or comma after each one.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Sensitivity")
                Picker("Sensitivity", selection: sensitivity(of: rule)) {
                    ForEach(Sensitivity.allCases, id: \.self) { level in
                        Text(verbatim: Self.title(for: level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Sensitivity")
                SettingsCaption(Self.explanation(for: rule.sensitivity))
            }
        }
    }

    private func sensitivity(of rule: Rule) -> Binding<Sensitivity> {
        Binding(
            get: { rule.sensitivity },
            set: { level in controller.edit(rule: ruleID) { $0.sensitivity = level } })
    }

    // MARK: Channels

    private func channelRow(_ kind: ChannelKind, in rule: Rule) -> some View {
        let isConfigured = controller.configuration.channels.isConfigured(kind)
        let isChecked = rule.channels.contains(kind)
        let needsPro = !controller.proPolicy.allows(kind)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(
                    kind.displayName,
                    isOn: Binding(
                        get: { isChecked },
                        set: { isOn in
                            controller.edit(rule: ruleID) {
                                if isOn { $0.channels.insert(kind) } else { $0.channels.remove(kind) }
                            }
                        })
                )
                .toggleStyle(.checkbox)
                .disabled(Self.isChannelDisabled(isConfigured: isConfigured, isChecked: isChecked, needsPro: needsPro))
                .accessibilityLabel("Alert with \(kind.displayName)")
                if needsPro { ProBadge { upsell.show(.channel(kind)) } }
                Spacer(minLength: 8)
                if needsPro {
                    Button(ProCopy.unlockTitle) { upsell.show(.channel(kind)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .font(.callout)
                        .accessibilityLabel("Unlock Pro for \(kind.displayName)")
                } else if !isConfigured {
                    Button("Set up in Alerts") { navigation.show(.alerts) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .font(.callout)
                        .accessibilityLabel("Set up \(kind.displayName) in Alerts")
                }
            }
            if needsPro, isChecked {
                SettingsCaption(ProCopy.channelNotSentOnFree)
            }
        }
    }

    /// Whether a channel's checkbox is unavailable: one that is not set up, or that needs Pro on Free, cannot be turned
    /// on; one that is on can always be turned off (its address was cleared, or Pro went away).
    static func isChannelDisabled(isConfigured: Bool, isChecked: Bool, needsPro: Bool = false) -> Bool {
        !isChecked && (needsPro || !isConfigured)
    }

    // MARK: Cooldown

    private func cooldownRow(_ rule: Rule) -> some View {
        LabeledContent("Wait before alerting again") {
            HStack(spacing: 8) {
                Text(verbatim: DurationText.short(rule.cooldownSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(
                    "Cooldown",
                    onIncrement: {
                        controller.edit(rule: ruleID) { $0.cooldownSeconds = CooldownSteps.increased($0.cooldownSeconds) }
                    },
                    onDecrement: {
                        controller.edit(rule: ruleID) { $0.cooldownSeconds = CooldownSteps.decreased($0.cooldownSeconds) }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Cooldown")
                .accessibilityValue(DurationText.spoken(rule.cooldownSeconds))
            }
        }
    }

    // MARK: Words

    static func title(for sensitivity: Sensitivity) -> String {
        switch sensitivity {
        case .exact: "Exact"
        case .balanced: "Balanced"
        case .loose: "Loose"
        }
    }

    static func explanation(for sensitivity: Sensitivity) -> String {
        switch sensitivity {
        case .exact: "Exact: only the exact word."
        case .balanced: "Balanced: allows small mishearings like Bhala for Bala."
        case .loose: "Loose: catches more, may alert on similar words."
        }
    }
}

/// The steps of the cooldown stepper: fine for short waits, coarser for long ones, so the whole range, 2 s to 10 min,
/// takes about thirty presses, and holding the button gets there quickly.
enum CooldownSteps {
    /// How far one press moves a cooldown of `seconds`.
    static func step(at seconds: Double) -> Double {
        switch seconds {
        case ..<10: 1
        case ..<30: 5
        case ..<120: 15
        case ..<300: 30
        default: 60
        }
    }

    /// The next step up, within the cooldown range.
    static func increased(_ seconds: Double) -> Double {
        let step = step(at: seconds)
        return clamp((seconds / step).rounded(.down) * step + step)
    }

    /// The next step down, within the cooldown range. A step down from a boundary uses the finer step below it.
    static func decreased(_ seconds: Double) -> Double {
        let step = step(at: seconds.nextDown)
        return clamp((seconds / step).rounded(.up) * step - step)
    }

    private static func clamp(_ seconds: Double) -> Double {
        min(max(seconds, Rule.cooldownRange.lowerBound), Rule.cooldownRange.upperBound)
    }
}

private struct MatchTesterSeedKey: EnvironmentKey {
    static var defaultValue: String { "" }
}

extension EnvironmentValues {
    /// The sentence the "Try a sentence" field starts with. Empty in the app; renders fill it.
    var matchTesterSeed: String {
        get { self[MatchTesterSeedKey.self] }
        set { self[MatchTesterSeedKey.self] = newValue }
    }
}
