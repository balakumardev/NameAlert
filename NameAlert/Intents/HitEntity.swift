import AppIntents
import Foundation
import NameAlertCore

/// One time a word was heard, as the Shortcuts app shows it.
struct HitEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mention"
    static let defaultQuery = HitQuery()

    let id: UUID
    @Property(title: "Word")
    var term: String
    @Property(title: "Rule")
    var ruleName: String
    @Property(title: "What was said")
    var context: String
    @Property(title: "Date")
    var date: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(term)", subtitle: "\(context)")
    }

    init(_ hit: Hit) {
        id = hit.id
        term = hit.term
        ruleName = hit.ruleName
        context = hit.context
        date = hit.timestamp
    }
}

/// Finds mentions in the history, newest first.
struct HitQuery: EntityQuery {
    /// How many mentions a picker offers.
    private static let suggestionCount = 20

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [HitEntity] {
        let wanted = Set(identifiers)
        let controller = await IntentEnvironment.controller()
        return await controller.history().filter { wanted.contains($0.id) }.map(HitEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [HitEntity] {
        let controller = await IntentEnvironment.controller()
        return await controller.history().prefix(Self.suggestionCount).map(HitEntity.init)
    }
}
