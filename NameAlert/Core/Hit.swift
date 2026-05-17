import Foundation

/// A single keyword match emitted by `KeywordMatcher`.
struct Hit: Sendable, Equatable {
    let keyword: String
    let matchedText: String
    let timestamp: Date
    let distance: Int
}
