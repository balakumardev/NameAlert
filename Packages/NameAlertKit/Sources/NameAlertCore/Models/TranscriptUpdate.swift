/// A recognizer's current text for one speech segment. Partial updates repeat the same `segmentID`
/// until the segment is final.
public struct TranscriptUpdate: Sendable, Equatable {
    public let segmentID: String
    public let text: String
    /// Other readings of the same audio, best first.
    public let alternatives: [String]
    public let isFinal: Bool

    public init(segmentID: String, text: String, alternatives: [String] = [], isFinal: Bool) {
        self.segmentID = segmentID
        self.text = text
        self.alternatives = alternatives
        self.isFinal = isFinal
    }
}
