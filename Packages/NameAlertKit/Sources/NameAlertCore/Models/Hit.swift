import Foundation

/// One time a rule's term was heard. This is also the record kept in the history.
public struct Hit: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let ruleID: UUID
    public let ruleName: String
    public let term: String
    public let matchedText: String
    public let context: String
    public let timestamp: Date
    public let source: AudioSourceKind
    public let engine: EngineID
    public let segmentID: String

    public init(
        id: UUID = UUID(), ruleID: UUID, ruleName: String, term: String, matchedText: String, context: String,
        timestamp: Date, source: AudioSourceKind, engine: EngineID, segmentID: String
    ) {
        self.id = id
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.term = term
        self.matchedText = matchedText
        self.context = context
        self.timestamp = timestamp
        self.source = source
        self.engine = engine
        self.segmentID = segmentID
    }
}
