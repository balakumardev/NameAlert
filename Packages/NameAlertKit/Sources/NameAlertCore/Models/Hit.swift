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
    /// The last half minute or so of the transcript, up to and including the match (at most 600 characters), so that
    /// the user can see what was just said. The listening controller fills it in after the rule engine has made the
    /// hit; it is `nil` when it is not known. A hit saved before this field existed reads back with `nil`, and a hit
    /// with `nil` is written without the key.
    public var excerpt: String?

    public init(
        id: UUID = UUID(), ruleID: UUID, ruleName: String, term: String, matchedText: String, context: String,
        timestamp: Date, source: AudioSourceKind, engine: EngineID, segmentID: String, excerpt: String? = nil
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
        self.excerpt = excerpt
    }
}
