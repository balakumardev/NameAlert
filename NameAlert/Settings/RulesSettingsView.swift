import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Settings → Rules: the list of rules with the one chosen open beside it, and the wait between any two alerts.
struct RulesSettingsView: View {
    static let listWidth: CGFloat = 240

    @Environment(ListeningController.self) private var controller

    @State private var selection: Rule.ID?
    @State private var pendingDeletion: Rule?
    /// The rule that was just added: its words field takes the keyboard.
    @State private var addedRuleID: Rule.ID?

    var body: some View {
        let rules = controller.configuration.rules
        let chosen = selection ?? rules.first?.id
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ruleList(rules, chosen: chosen)
                ListButtons(
                    canDelete: chosen != nil,
                    add: addRule,
                    delete: { pendingDeletion = rules.first { $0.id == chosen } })
                Divider()
                GlobalCooldownControl(seconds: controller.configuration.globalCooldownSeconds)
            }
            .frame(width: Self.listWidth)

            Divider()

            if let chosen {
                RuleEditorView(ruleID: chosen, focusesWords: chosen == addedRuleID)
                    .id(chosen)
            } else {
                ContentUnavailableView {
                    Label("No rules yet", systemImage: "text.badge.checkmark")
                } description: {
                    Text("Add a name or phrase to listen for.")
                } actions: {
                    Button("Add Rule", action: addRule)
                        .accessibilityLabel("Add a rule")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selection) { _, new in
            if new != addedRuleID { addedRuleID = nil }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion.map(RuleRow.title(of:)) ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { rule in
            Button("Delete", role: .destructive) { delete(rule, from: rules) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will stop alerting. This can't be undone.")
        }
    }

    private func ruleList(_ rules: [Rule], chosen: Rule.ID?) -> some View {
        List(selection: Binding(get: { chosen }, set: { selection = $0 })) {
            ForEach(rules) { rule in
                RuleRow(
                    rule: rule,
                    isEnabled: Binding(
                        get: { rule.isEnabled },
                        set: { enabled in controller.edit(rule: rule.id) { $0.isEnabled = enabled } })
                )
                .tag(rule.id)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .accessibilityLabel("Rules")
    }

    private func addRule() {
        let rule = Rule(name: "New rule", terms: [])
        controller.edit { $0.rules.append(rule) }
        selection = rule.id
        addedRuleID = rule.id
    }

    private func delete(_ rule: Rule, from rules: [Rule]) {
        // The rule next in the list, else the one before it, takes the place in the editor.
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            let next = rules.indices.contains(index + 1) ? rules[index + 1] : (index > 0 ? rules[index - 1] : nil)
            selection = next?.id
        }
        let id = rule.id
        controller.edit { $0.rules.removeAll { $0.id == id } }
    }
}

/// One rule in the list: its name, the words it listens for, and whether it is on.
struct RuleRow: View {
    let rule: Rule
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.title(of: rule))
                    .lineLimit(1)
                Text(verbatim: Self.summary(of: rule))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(rule.isEnabled ? 1 : 0.6)
            Spacer(minLength: 4)
            Toggle("Enabled", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Enable \(Self.title(of: rule))")
        }
        .padding(.vertical, 2)
    }

    static func title(of rule: Rule) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled rule" : name
    }

    /// "Bala, Balakumar, Bala Kumar", or "No words yet".
    static func summary(of rule: Rule) -> String {
        let terms = rule.terms.compactMap { PopoverActions.keyword(from: $0) }
        return terms.isEmpty ? "No words yet" : terms.joined(separator: ", ")
    }
}

/// The + and − under the list.
private struct ListButtons: View {
    let canDelete: Bool
    let add: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: add) {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .help("Add a rule")
            .accessibilityLabel("Add a rule")
            Button(action: delete) {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .disabled(!canDelete)
            .help("Delete the selected rule")
            .accessibilityLabel("Delete the selected rule")
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }
}

/// "Wait between any two alerts": the global cooldown, 0 to 30 seconds.
struct GlobalCooldownControl: View {
    private let seconds: Double
    @Environment(ListeningController.self) private var controller
    @State private var shown: Double

    init(seconds: Double) {
        self.seconds = seconds
        _shown = State(initialValue: seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wait between any two alerts")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                DraftSlider(
                    "Wait between any two alerts", value: seconds, in: AppConfiguration.globalCooldownRange, step: 1
                ) { new in
                    shown = new
                    controller.edit { $0.globalCooldownSeconds = new }
                }
                .accessibilityValue(DurationText.spoken(shown))
                Text(verbatim: DurationText.short(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .accessibilityElement(children: .contain)
            SettingsCaption("Mentions closer together than this are skipped.")
        }
        .padding(12)
    }
}
