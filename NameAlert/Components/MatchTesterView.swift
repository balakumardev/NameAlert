import Foundation
import NameAlertCore
import SwiftUI

/// "Try a sentence": type something and see whether the rule would alert, with the words that matched highlighted in
/// the sentence. It asks `RuleEngine` the same question the listening does.
struct MatchTesterView: View {
    let rule: Rule

    @State private var sentence: String

    /// `initialSentence` fills the field from the start, for renders.
    init(rule: Rule, initialSentence: String = "") {
        self.rule = rule
        _sentence = State(initialValue: initialSentence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Try a sentence", text: $sentence,
                prompt: Text("Something someone might say").foregroundStyle(.secondary))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .accessibilityLabel("Try a sentence")
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        switch Self.outcome(of: sentence, rule: rule) {
        case .empty:
            SettingsCaption("Type a sentence to see whether this rule would alert.")
        case .noWords:
            SettingsCaption("Add a word to listen for first.")
        case .noMatch:
            Label("No match", systemImage: "minus.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .matches(let highlighted, let count):
            VStack(alignment: .leading, spacing: 4) {
                Text(highlighted)
                    .fixedSize(horizontal: false, vertical: true)
                Label(count == 1 ? "Match" : "\(count) matches", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                if !rule.isEnabled {
                    SettingsCaption("This rule is off, so it won't alert.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// What the tester shows for a sentence.
    enum Outcome: Equatable {
        case empty
        case noWords
        case noMatch
        /// The sentence with the matched words marked, and how many matches there are.
        case matches(AttributedString, count: Int)
    }

    static func outcome(of sentence: String, rule: Rule) -> Outcome {
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard rule.terms.contains(where: { PopoverActions.keyword(from: $0) != nil }) else { return .noWords }
        let matches = RuleEngine.matches(in: sentence, rule: rule)
        guard !matches.isEmpty else { return .noMatch }
        return .matches(highlighted(sentence, matches: matches), count: matches.count)
    }

    /// `sentence` with each match's words in bold on the accent color. A match is the words as they were written, so
    /// they are found in the sentence in order, each after the one before.
    static func highlighted(_ sentence: String, matches: [MatchResult]) -> AttributedString {
        var text = AttributedString(sentence)
        var from = sentence.startIndex
        for match in matches {
            guard !match.matchedText.isEmpty,
                let found = sentence.range(of: match.matchedText, range: from..<sentence.endIndex),
                let range = Range(found, in: text)
            else { continue }
            text[range].font = .body.bold()
            text[range].backgroundColor = Color.accentColor.opacity(0.3)
            from = found.upperBound
        }
        return text
    }

    /// The marked parts of `text`, as plain strings, for tests.
    static func markedParts(of text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.backgroundColor == nil ? nil : String(text[run.range].characters)
        }
    }
}
