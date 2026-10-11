import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// What is being heard right now: the words as they come in, with the ones a rule listens for marked, and the last
/// mention under them. Nothing in this window is saved: the text lives in the window and goes when it closes.
struct LiveTranscriptWindow: View {
    static let minimumSize = CGSize(width: 520, height: 360)

    /// What the window says when there is nothing to show yet.
    static let waitingMessage = "Waiting for someone to speak…"
    static let notListeningMessage = "Not listening right now. Words appear here as they are heard."
    static let privacyNote = "Nothing here is saved."

    @Environment(ListeningController.self) private var controller

    /// The text shown: the controller keeps the last 300 characters, this keeps the last 2 000 for as long as the
    /// window is open.
    @State private var buffer: LiveTranscriptBuffer
    @State private var autoScroll = true

    /// `initialText` is what the window starts with, for renders; the app starts empty and fills from what is heard.
    init(initialText: String = "") {
        _buffer = State(initialValue: LiveTranscriptBuffer(seed: initialText))
    }

    private static let endID = "end"

    var body: some View {
        VStack(spacing: 0) {
            LiveHeader()
            Divider()
            transcript
            if let hit = controller.recentHits.first {
                Divider()
                HistoryDetail(hit: hit, title: Self.lastMentionTitle(for: hit), textHeight: 64)
                    .padding(.horizontal, 4)  // in line with the header, the text and the footer: 16 points in
            }
            Divider()
            footer
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .onChange(of: controller.liveTranscript, initial: true) { _, window in
            buffer.take(window)
        }
    }

    // MARK: Parts

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if buffer.isEmpty {
                            Text(verbatim: emptyMessage)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TranscriptText(text: buffer.text, rules: controller.configuration.rules)
                                .equatable()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.endID)
                    }
                    .padding(16)
                    // A short text stays at the top of the window; a long one runs on past the bottom.
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)  // new words come in at the end
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: buffer) { scrollToEnd(proxy) }
                .onChange(of: autoScroll) { scrollToEnd(proxy) }
                .accessibilityLabel("Live transcript")
            }
        }
    }

    private var emptyMessage: String {
        switch controller.state {
        case .listening, .preparing: Self.waitingMessage
        case .off, .waitingForCall, .snoozed, .error: Self.notListeningMessage
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard autoScroll else { return }
        proxy.scrollTo(Self.endID, anchor: .bottom)
    }

    private var footer: some View {
        HStack {
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Auto-scroll")
            Spacer()
            Text(verbatim: Self.privacyNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// "Last mention, 10:32 AM · My name".
    static func lastMentionTitle(for hit: Hit, now: Date = Date()) -> String {
        "Last mention, \(HitRow.time(of: hit.timestamp, now: now)) · \(hit.ruleName)"
    }
}

/// The transcript with what rules listen for marked. Its own view, so the marking is worked out again only when the
/// text or the rules change.
private struct TranscriptText: View, Equatable {
    let text: String
    let rules: [Rule]

    var body: some View {
        Text(TextHighlighting.highlighted(text, rules: rules, font: .body))
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header

/// The top of the window: the status dot and line like the popover's, the engine and language under it, and the
/// level.
struct LiveHeader: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let state = controller.state
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    StatusText(state: state)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(verbatim: Self.details(for: state, active: controller.activeEngine, configuration: controller.configuration))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 16)  // under the status text, past the dot
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            HeaderLevelMeter()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Under the status: the engine and the language while listening; the engine while getting ready; else the audio
    /// source that is chosen.
    static func details(for state: ListeningState, active: EngineID?, configuration: AppConfiguration) -> String {
        if case .listening(let info) = state {
            return "\(StatusText.engineName(info.engine)) · \(SpeechLanguages.title(for: info.localeIdentifier))"
        }
        if let engine = PopoverHeader.engine(for: state, active: active, configuration: configuration) {
            return StatusText.engineName(engine)
        }
        return StatusText.sourceName(configuration.listening.source)
    }
}

/// The level meter, reading the level itself: it changes up to 15 times a second and only this view follows it.
private struct HeaderLevelMeter: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        LevelMeter(level: controller.level)
    }
}

// MARK: - The text kept

/// The text the window keeps from what the controller shows: up to 2 000 characters.
///
/// The controller shows only the last 300 characters of what was heard, and changes that window as words come in: it
/// ends in newer words, may start later, and may have changed its last words (the engine revises what it is still
/// working on). `take(_:)` follows that. What slides out of the window stays here, and the window itself is kept as it
/// was last, so that the next one can replace it.
struct LiveTranscriptBuffer: Equatable {
    /// The most characters kept.
    static let limit = 2_000

    /// How many characters the controller's window holds. A shorter window holds everything heard in its run.
    static let windowLimit = 300

    /// How much of the start of a window is used to find where it starts in the one before.
    static let anchorLength = 24

    /// What slid out of the window, and earlier runs, with the break between them.
    private var committed = ""
    /// The window as it was last.
    private var current = ""

    init() {}

    /// A buffer that already holds `seed`, as if its last 300 characters were the window. For renders.
    init(seed: String) {
        let seed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard seed.count > Self.windowLimit else {
            current = seed
            return
        }
        let tail = seed.suffix(Self.windowLimit)
        var start = tail.startIndex
        if let space = tail.firstIndex(where: \.isWhitespace) { start = tail.index(after: space) }
        committed = String(seed[..<start])
        current = String(tail[start...])
    }

    /// Everything kept, oldest first.
    var text: String { committed + current }

    var isEmpty: Bool { committed.isEmpty && current.isEmpty }

    /// Takes in the controller's latest window.
    ///
    /// - A window that starts in the one before it (its first words are found there) takes its place, and what came
    ///   before it in the old window stays: the words slid out of the window, or none did.
    /// - Two windows that both hold a whole run, where the second does not start in the first, are two readings of
    ///   the same words, the engine having changed the first ones: the new one takes its place.
    /// - Any other window is new words after a gap: it goes after what is kept, with a space.
    /// - An empty window means nothing is being heard (listening stopped): what is kept stays, and the next words
    ///   start a new line.
    mutating func take(_ window: String) {
        let window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        if window.isEmpty {
            if !current.isEmpty {
                committed += current + "\n"
                current = ""
            }
            return
        }
        if current.isEmpty {
            current = window
        } else if let slid = Self.start(of: window, in: current) {
            committed += current[..<slid]
            current = window
        } else if current.count < Self.windowLimit, window.count < Self.windowLimit {
            current = window
        } else {
            committed += current + " "
            current = window
        }
        trim()
    }

    /// Where `window` starts in `old`: where its first words are found, at the place that agrees with it for longest.
    private static func start(of window: String, in old: String) -> String.Index? {
        let anchor = String(window.prefix(anchorLength))
        var best: (index: String.Index, agreement: Int)?
        var from = old.startIndex
        while let found = old.range(of: anchor, range: from..<old.endIndex) {
            let agreement = zip(old[found.lowerBound...], window).prefix { $0 == $1 }.count
            if best == nil || agreement > best!.agreement { best = (found.lowerBound, agreement) }
            from = old.index(after: found.lowerBound)
        }
        return best?.index
    }

    /// Cuts the oldest words to keep within `limit`, at the start of a word.
    private mutating func trim() {
        let excess = committed.count + current.count - Self.limit
        guard excess > 0 else { return }
        guard committed.count > excess else {
            committed = ""
            return
        }
        var kept = committed.dropFirst(excess)
        if let space = kept.firstIndex(where: \.isWhitespace) { kept = kept[kept.index(after: space)...] }
        committed = String(kept)
    }
}
