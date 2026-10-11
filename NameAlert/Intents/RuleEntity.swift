import AppIntents
import Foundation
import NameAlertCore

/// A rule, as the Shortcuts app shows and picks it.
struct RuleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rule"
    static let defaultQuery = RuleQuery()

    let id: UUID
    @Property(title: "Name")
    var name: String
    @Property(title: "Words")
    var termsSummary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(termsSummary)")
    }

    init(_ rule: Rule) {
        id = rule.id
        name = rule.name
        termsSummary = rule.terms.joined(separator: ", ")
    }
}

/// Finds rules for the pickers in Shortcuts: all of them, those with an ID, or those whose name or words match what
/// was typed.
struct RuleQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [RuleEntity] {
        let rules = await Self.rules()
        return identifiers.compactMap { id in rules.first { $0.id == id }.map(RuleEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [RuleEntity] {
        let rules = await Self.rules()
        let search = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return rules.map(RuleEntity.init) }
        return rules
            .filter { rule in
                rule.name.localizedStandardContains(search)
                    || rule.terms.contains { $0.localizedStandardContains(search) }
            }
            .map(RuleEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [RuleEntity] {
        await Self.rules().map(RuleEntity.init)
    }

    @MainActor
    private static func rules() async -> [Rule] {
        await IntentEnvironment.controller().configuration.rules
    }
}
