import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Reads the history from the controller and hands it to `content`, newest first, again each time a new mention is
/// recorded. A view that needs to read it again for another reason (the history was cleared) changes `reloadToken`.
struct HistoryLoader<Content: View>: View {
    var reloadToken = 0
    @ViewBuilder let content: ([Hit]) -> Content

    @Environment(ListeningController.self) private var controller
    @State private var hits: [Hit] = []

    var body: some View {
        content(hits)
            .task(id: LoadKey(lastHitAt: controller.lastHitAt, reloadToken: reloadToken)) {
                hits = await controller.history()
            }
    }

    private struct LoadKey: Equatable {
        let lastHitAt: Date?
        let reloadToken: Int
    }
}

/// The mentions in a table: when, which rule, what was heard, what was said around it, and where it came from. The
/// search field filters them; a chosen row shows what was said just before it under the table.
struct HistoryTable: View {
    let hits: [Hit]
    /// The time the times are written against ("Yesterday"). The app uses the clock; renders fix it.
    var now: Date = Date()

    @Environment(\.historyStart) private var start
    @State private var searchText = ""
    @State private var selection: Hit.ID?

    /// What a table can be made to start with, for renders: a search, and a chosen row.
    struct Start: Equatable {
        var searchText = ""
        var selection: Hit.ID?
    }

    /// What the empty table says.
    static let emptyMessage = "Nothing yet. When someone says one of your keywords it shows up here."

    var body: some View {
        let shown = Self.filter(hits, matching: searchText)
        let chosen = shown.first { $0.id == selection }
        VStack(spacing: 0) {
            if hits.isEmpty {
                emptyState
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table(shown)
            }
            if let chosen {
                Divider()
                HistoryDetail(hit: chosen, close: { selection = nil })
                    .id(chosen.id)
            }
        }
        .searchable(text: $searchText, prompt: "Search mentions")
        .onAppear {
            if !start.searchText.isEmpty { searchText = start.searchText }
            if selection == nil { selection = start.selection }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // No `fixedSize` here: outside a scroll view, it makes the text ask for a very tall space at no width, and
            // the window that holds it would ask for the same.
            Text(verbatim: Self.emptyMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func table(_ rows: [Hit]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Time") { hit in
                let when = Self.when(of: hit.timestamp, now: now)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: when.day)
                    Text(verbatim: when.time)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(when.spoken)
            }
            .width(66)

            // The narrow columns have the width their words need and no more (each also gets its cell's padding); the
            // context takes what is left.
            TableColumn("Rule") { hit in
                Text(verbatim: hit.ruleName)
                    .lineLimit(2)
            }
            .width(64)

            TableColumn("Heard") { hit in
                Text(verbatim: Self.heard(by: hit))
                    .bold()
                    .lineLimit(2)
            }
            .width(80)

            TableColumn("Context") { hit in
                // From a few words before the match, so that the words that were heard stay in view.
                Text(verbatim: HitRow.focusedContext(of: hit, wordsBefore: 4))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: 120)

            TableColumn("Source") { hit in
                Text(verbatim: GeneralSettingsView.title(for: hit.source))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(86)
        }
        // A table asks for as much height as it has rows to show; without this, a pane that holds it asks its window for
        // a height of its own (the Settings window takes its size from what its panes ask for).
        .frame(minHeight: 140, idealHeight: 240, maxHeight: .infinity)
        .accessibilityLabel("Mentions")
    }

    // MARK: Words

    /// When a mention was heard, in two lines: "Today" and "10:32 AM", "Yesterday" and "5:12 PM", "Oct 9" and
    /// "5:12 PM", with the year when it was another year.
    struct When: Equatable {
        let day: String
        let time: String

        /// For VoiceOver.
        var spoken: String { "\(day), \(time)" }
    }

    static func when(of date: Date, now: Date, calendar: Calendar = .current) -> When {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return When(day: "Today", time: time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return When(day: "Yesterday", time: time)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return When(day: day, time: time)
    }

    /// The words as they were heard, which may differ from the rule's word ("Bhala" for "Bala").
    static func heard(by hit: Hit) -> String {
        let heard = hit.matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return heard.isEmpty ? hit.term : heard
    }

    /// The hits that match every word of `query` in the rule's word, what was heard, the rule's name or the context,
    /// ignoring case and accents. All of them when `query` is blank.
    static func filter(_ hits: [Hit], matching query: String) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return hits }
        return hits.filter { hit in
            let fields = [hit.term, hit.matchedText, hit.ruleName, hit.context]
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }
}

/// What was said just before a mention, with the heard words marked: under the history table for the chosen row, and
/// in the live transcript for the last mention. Older entries that have no excerpt show the context they kept.
struct HistoryDetail: View {
    let hit: Hit
    /// The line above the text; by default what the text is ("What was said").
    var title: String?
    /// The most height the text takes before it scrolls.
    var textHeight: CGFloat = 104
    /// Hides the details, with a button for it; no button without it.
    var close: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title ?? Self.title(for: hit))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide")
                    .accessibilityLabel("Hide what was said")
                }
            }
            CappedScrollView(maxHeight: textHeight) { text }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var text: some View {
        Text(Self.marked(hit))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Words

    static func title(for hit: Hit) -> String {
        Self.excerpt(of: hit) == nil ? "Around the mention" : "What was said"
    }

    /// The excerpt, when the hit has one that says something.
    static func excerpt(of hit: Hit) -> String? {
        guard let excerpt = hit.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty else { return nil }
        return excerpt
    }

    /// The text shown for a hit: its excerpt, else its context, with the heard words marked.
    static func marked(_ hit: Hit) -> AttributedString {
        let text = excerpt(of: hit) ?? hit.context
        let heard = HistoryTable.heard(by: hit)
        var ranges = TextHighlighting.occurrences(of: heard, in: text)
        if ranges.isEmpty, heard != hit.term { ranges = TextHighlighting.occurrences(of: hit.term, in: text) }
        return TextHighlighting.marked(text, ranges: ranges)
    }
}

private struct HistoryStartKey: EnvironmentKey {
    static var defaultValue: HistoryTable.Start { HistoryTable.Start() }
}

extension EnvironmentValues {
    /// What the history table starts with. Empty in the app; renders fill it.
    var historyStart: HistoryTable.Start {
        get { self[HistoryStartKey.self] }
        set { self[HistoryStartKey.self] = newValue }
    }
}

/// A scroll view that is as tall as its content, up to `maxHeight`, and scrolls beyond that. It starts at the end of
/// the content.
struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .defaultScrollAnchor(.bottom)  // a mention's text ends with the match: its words come first
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
    }
}
