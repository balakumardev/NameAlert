import AppIntents
import Foundation
import NameAlertCore

/// Why a rule intent could not do what it was asked. The text is what Shortcuts shows.
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case emptyKeyword
    case ruleNotFound
    case ruleLimit

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyKeyword: "Type a word or phrase to listen for."
        case .ruleNotFound: "That rule no longer exists."
        case .ruleLimit:
            "Free alerts with up to \(ProPolicy.freeRuleLimit) rules. Pick a rule to add the word to, or get Pro in Settings."
        }
    }
}

struct AddKeywordIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Keyword"
    static let description = IntentDescription("Listen for a new word or phrase.")
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Listen for \(\.$term)") {
            \.$rule
        }
    }

    @Parameter(title: "Word or phrase")
    var term: String

    @Parameter(title: "Rule", description: "Add the word to this rule. Leave it empty to make a new rule.")
    var rule: RuleEntity?

    /// With a rule, the word joins that rule's words (once). Without one, it becomes a rule of its own, named after the
    /// word, with Sound and Notification alerts, like "Add keyword" in the menu bar.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RuleEntity> & ProvidesDialog {
        guard let keyword = PopoverActions.keyword(from: term) else { throw IntentFailure.emptyKeyword }
        let controller = await IntentEnvironment.controller()
        let saved: Rule
        if let chosenRuleID = rule?.id {
            var updated: Rule?
            await controller.update { configuration in
                guard let index = configuration.rules.firstIndex(where: { $0.id == chosenRuleID }) else { return }
                if !configuration.rules[index].terms.contains(where: { Self.isSameWord($0, keyword) }) {
                    configuration.rules[index].terms.append(keyword)
                }
                updated = configuration.rules[index]
            }
            guard let updated else { throw IntentFailure.ruleNotFound }
            saved = updated
        } else {
            let new = Rule(name: keyword, terms: [keyword])
            // Free's most rules are there: the controller refuses, and Shortcuts says why.
            guard await controller.addRule(new) else { throw IntentFailure.ruleLimit }
            saved = new
        }
        return .result(value: RuleEntity(saved), dialog: IntentEnvironment.dialog("Added “\(keyword)”."))
    }

    /// Whether two words are the same, ignoring case and accents.
    private static func isSameWord(_ first: String, _ second: String) -> Bool {
        first.compare(second, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

struct SetRuleEnabledIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Rule Enabled"
    static let description = IntentDescription("Turn a rule on or off.")
    static let openAppWhenRun = false

    @Parameter(title: "Rule")
    var rule: RuleEntity

    @Parameter(title: "Enabled", default: true)
    var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RuleEntity> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        let chosenRuleID = rule.id
        let isEnabled = enabled
        var saved: Rule?
        await controller.update { configuration in
            guard let index = configuration.rules.firstIndex(where: { $0.id == chosenRuleID }) else { return }
            configuration.rules[index].isEnabled = isEnabled
            saved = configuration.rules[index]
        }
        guard let saved else { throw IntentFailure.ruleNotFound }
        let heldBack = controller.proPolicy.heldBackRuleIDs(in: controller.configuration.rules).contains(saved.id)
        let dialog =
            isEnabled
            ? (heldBack
                ? "Turned on “\(saved.name)”. It alerts with Pro, or once another rule is off."
                : "Turned on “\(saved.name)”.")
            : "Turned off “\(saved.name)”."
        return .result(value: RuleEntity(saved), dialog: IntentEnvironment.dialog(dialog))
    }
}
