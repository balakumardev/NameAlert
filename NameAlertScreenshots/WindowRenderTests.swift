import AppKit
import CryptoKit
import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

/// The Settings window at its minimum size, 760 × 540 points.
private let paneSize = CGSize(width: 760, height: 540)

/// How long a render lets what a view asks for in a task (the history, the licenses text) come back before the
/// picture is taken.
private let settleTime = Duration.milliseconds(500)

@Suite("History, API and About renders", .serialized)
@MainActor
struct HistoryApiAboutRenderTests {
    private func appearance(_ dark: Bool) -> NSAppearance.Name { dark ? .darkAqua : .aqua }
    private func suffix(_ dark: Bool) -> String { dark ? "-dark" : "" }

    // MARK: History

    @Test("History settings render five mentions with one opened", arguments: [false, true])
    func historySettings(dark: Bool) async throws {
        let hits = DemoFixtures.historyHits
        let controller = await SettingsFixtures.controller(history: hits)
        let view = SettingsRenderFrame {
            SettingsView(section: .history)
                .environment(controller)
                .environment(\.historyStart, HistoryTable.Start(selection: hits[0].id))
        }
        try await RenderHarness.render(
            view, size: paneSize, name: "settings-history" + suffix(dark), appearance: appearance(dark),
            afterWaiting: settleTime)
    }

    @Test("History settings render a mention that has no excerpt, history turned off, and nothing yet")
    func historySettingsVariants() async throws {
        let hits = DemoFixtures.historyHits
        let controller = await SettingsFixtures.controller(history: hits)
        try await RenderHarness.render(
            SettingsRenderFrame {
                SettingsView(section: .history)
                    .environment(controller)
                    .environment(\.historyStart, HistoryTable.Start(selection: hits[2].id))
            }, size: paneSize, name: "settings-history-context", afterWaiting: settleTime)

        var off = DemoFixtures.settingsConfiguration
        off.history.isEnabled = false
        let offController = await SettingsFixtures.controller(configuration: off)
        try await RenderHarness.render(
            SettingsRenderFrame {
                SettingsView(section: .history)
                    .environment(offController)
            }, size: paneSize, name: "settings-history-empty", afterWaiting: settleTime)
    }

    @Test("The History window renders at its minimum size and larger", arguments: [false, true])
    func historyWindow(dark: Bool) async throws {
        let hits = DemoFixtures.historyHits
        let controller = await SettingsFixtures.controller(history: hits)
        let view = SettingsRenderFrame {
            HistoryWindow()
                .environment(controller)
                .environment(\.historyStart, HistoryTable.Start(selection: hits[0].id))
        }
        try await RenderHarness.render(
            view, size: HistoryWindow.minimumSize, name: "history-window" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: CGSize(width: 900, height: 560), name: "history-window-large" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
    }

    @Test("The History window renders with no mentions, and with a search nothing matches")
    func historyWindowStates() async throws {
        let empty = await SettingsFixtures.controller()
        try await RenderHarness.render(
            SettingsRenderFrame { HistoryWindow().environment(empty) }, size: HistoryWindow.minimumSize,
            name: "history-window-empty", afterWaiting: settleTime)

        let controller = await SettingsFixtures.controller(history: DemoFixtures.historyHits)
        try await RenderHarness.render(
            SettingsRenderFrame {
                HistoryWindow()
                    .environment(controller)
                    .environment(\.historyStart, HistoryTable.Start(searchText: "budget"))
            }, size: HistoryWindow.minimumSize, name: "history-window-no-results", afterWaiting: settleTime)
    }

    // MARK: Size

    /// The height a Settings pane asks its window for, once it has what it shows. The Settings window takes its size
    /// from what the pane that opens first asks for: a pane that asks for more makes it open taller than its minimum.
    private func askedHeight(of section: SettingsSection, controller: ListeningController) async throws -> CGFloat {
        let capabilities = SettingsFixtures.capabilities
        let root = SettingsRenderFrame {
            SettingsView(section: section)
                .environment(controller)
                .environment(WindowRouter())
                .environment(SecretsModel(store: InMemorySecretStore()))
                .environment(\.speechCapabilities, { capabilities })
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: paneSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: settleTime)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        window.contentView = nil
        return height
    }

    @Test("No Settings pane asks its window for more than the minimum height, whatever it shows")
    func panesAskForNoMoreThanTheMinimum() async throws {
        let full = await SettingsFixtures.controller(history: DemoFixtures.historyHits)
        for section in SettingsSection.allCases {
            let height = try await askedHeight(of: section, controller: full)
            #expect(height <= paneSize.height, "\(section.title) asks for \(height) points")
        }
        // History with nothing in it, and with history turned off.
        let empty = await SettingsFixtures.controller()
        #expect(try await askedHeight(of: .history, controller: empty) <= paneSize.height)
        var off = DemoFixtures.settingsConfiguration
        off.history.isEnabled = false
        let notKept = await SettingsFixtures.controller(configuration: off, history: DemoFixtures.historyHits)
        #expect(try await askedHeight(of: .history, controller: notKept) <= paneSize.height)
    }

    /// The smallest size SwiftUI says a view can be: what a window takes as its own minimum.
    private func smallestSize<V: View>(of view: V) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: .zero)
    }

    @Test("The windows can be as small as their minimum, with or without anything in them")
    func windowsCanBeSmall() async throws {
        let empty = await SettingsFixtures.controller()
        let full = await SettingsFixtures.controller(history: DemoFixtures.historyHits)
        for controller in [empty, full] {
            let history = smallestSize(of: HistoryWindow().environment(controller))
            #expect(history.width <= HistoryWindow.minimumSize.width && history.height <= HistoryWindow.minimumSize.height,
                "History can only shrink to \(history)")
        }
        for state in [ListeningState.off, .listening(DemoFixtures.listeningInfo)] {
            let live = smallestSize(
                of: LiveTranscriptWindow(initialText: DemoFixtures.longTranscript)
                    .environment(DemoFixtures.controller(state, hits: DemoFixtures.historyHits, transcript: DemoFixtures.liveWindow)))
            #expect(live.width <= LiveTranscriptWindow.minimumSize.width && live.height <= LiveTranscriptWindow.minimumSize.height,
                "The live transcript can only shrink to \(live)")
        }
    }

    // MARK: Shortcuts & API

    @Test("Shortcuts and API render from the top, the bottom, and whole", arguments: [false, true])
    func api(dark: Bool) async throws {
        let view = SettingsRenderFrame {
            SettingsView(section: .shortcuts)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
        }
        let name = "settings-api"
        try await RenderHarness.render(
            view, size: paneSize, name: name + suffix(dark), appearance: appearance(dark), afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: paneSize, name: name + "-bottom" + suffix(dark), appearance: appearance(dark),
            scrollsToEnd: true, afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: CGSize(width: 760, height: 1500), name: name + "-full" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
    }

    // MARK: About

    @Test("About renders with Acknowledgements closed", arguments: [false, true])
    func about(dark: Bool) async throws {
        let view = SettingsRenderFrame {
            SettingsView(section: .about)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
                .environment(WindowRouter())
        }
        try await RenderHarness.render(
            view, size: paneSize, name: "settings-about" + suffix(dark), appearance: appearance(dark),
            afterWaiting: settleTime)
    }

    @Test("About renders with the Acknowledgements open", arguments: [false, true])
    func aboutAcknowledgements(dark: Bool) async throws {
        let view = SettingsRenderFrame {
            AboutSettingsView(showsAcknowledgements: true)
                .frame(width: 580)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration))
                .environment(WindowRouter())
        }
        try await RenderHarness.render(
            view, size: CGSize(width: 580, height: 800), name: "settings-about-acknowledgements" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
    }

    // MARK: Live transcript

    private func liveController(
        state: ListeningState, hits: [Hit], transcript: String, level: Double
    ) -> ListeningController {
        DemoFixtures.controller(state, hits: hits, transcript: transcript, level: level)
    }

    @Test("The live transcript renders at its minimum size and at its opening size", arguments: [false, true])
    func liveWindow(dark: Bool) async throws {
        let controller = liveController(
            state: .listening(DemoFixtures.listeningInfo), hits: DemoFixtures.historyHits,
            transcript: DemoFixtures.liveWindow, level: 0.4)
        let view = SettingsRenderFrame {
            LiveTranscriptWindow(initialText: DemoFixtures.longTranscript)
                .environment(controller)
        }
        try await RenderHarness.render(
            view, size: LiveTranscriptWindow.minimumSize, name: "live-window" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
        try await RenderHarness.render(
            view, size: CGSize(width: 620, height: 460), name: "live-window-large" + suffix(dark),
            appearance: appearance(dark), afterWaiting: settleTime)
    }

    @Test("The live transcript renders waiting for speech, paused, and with a mention that has no excerpt")
    func liveWindowStates() async throws {
        let waiting = liveController(
            state: .listening(DemoFixtures.listeningInfo), hits: [], transcript: "", level: 0.05)
        try await RenderHarness.render(
            SettingsRenderFrame { LiveTranscriptWindow().environment(waiting) },
            size: LiveTranscriptWindow.minimumSize, name: "live-window-waiting", afterWaiting: settleTime)

        let paused = liveController(state: .off, hits: Array(DemoFixtures.historyHits.suffix(3)), transcript: "", level: 0)
        try await RenderHarness.render(
            SettingsRenderFrame { LiveTranscriptWindow().environment(paused) },
            size: LiveTranscriptWindow.minimumSize, name: "live-window-paused", afterWaiting: settleTime)

        let noExcerpt = liveController(
            state: .listening(DemoFixtures.listeningInfo), hits: Array(DemoFixtures.historyHits.suffix(3)),
            transcript: DemoFixtures.liveWindow, level: 0.7)
        try await RenderHarness.render(
            SettingsRenderFrame {
                LiveTranscriptWindow(initialText: DemoFixtures.longTranscript).environment(noExcerpt)
            }, size: LiveTranscriptWindow.minimumSize, name: "live-window-context", afterWaiting: settleTime)
    }
}

// MARK: - Logic

@Suite("History, API and About logic")
@MainActor
struct HistoryApiAboutLogicTests {
    private let calendar = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    // MARK: History table

    @Test("The history search matches the word, what was heard, the rule and the context, every word of it")
    func historySearch() {
        let hits = DemoFixtures.historyHits
        let names: ([Hit]) -> [String] = { $0.map { "\($0.term)/\($0.matchedText)" } }
        #expect(HistoryTable.filter(hits, matching: "   ").count == 5)
        #expect(names(HistoryTable.filter(hits, matching: "bhala")) == ["Bala/Bhala"])
        // "bala" is in the word, in what was heard and in the context.
        #expect(names(HistoryTable.filter(hits, matching: "BALA")) == ["Bala/Bala", "Bala/Bhala", "Balakumar/Bala Kumar"])
        // Accents are ignored.
        #expect(HistoryTable.filter(hits, matching: "bála").count == 3)
        // The rule's name.
        #expect(HistoryTable.filter(hits, matching: "my name").count == 3)
        #expect(names(HistoryTable.filter(hits, matching: "standup")) == ["standup/standup", "stand-up/stand up"])
        // Every word has to be found, each anywhere.
        #expect(names(HistoryTable.filter(hits, matching: "thanks helps")) == ["Bala/Bhala"])
        #expect(HistoryTable.filter(hits, matching: "thanks nothing").isEmpty)
        // The excerpt is for reading, not for the search: "roadmap" is only in it.
        #expect(DemoFixtures.historyHits[0].excerpt?.contains("roadmap") == true)
        #expect(HistoryTable.filter(hits, matching: "roadmap").isEmpty)
    }

    @Test("Times read as Today, Yesterday, a day, and a day with its year, over the time")
    func historyTimes() {
        let now = date(2026, 10, 12, 12, 0)
        let time = { (hour: Int, minute: Int) in
            self.date(2026, 10, 12, hour, minute).formatted(date: .omitted, time: .shortened)
        }
        #expect(HistoryTable.when(of: date(2026, 10, 12, 10, 32), now: now)
            == HistoryTable.When(day: "Today", time: time(10, 32)))
        let yesterday = HistoryTable.when(of: date(2026, 10, 11, 17, 12), now: now)
        #expect(yesterday == HistoryTable.When(day: "Yesterday", time: time(17, 12)))
        #expect(yesterday.spoken == "Yesterday, \(time(17, 12))")
        let earlier = HistoryTable.when(of: date(2026, 6, 3, 9, 5), now: now)
        #expect(earlier.time == time(9, 5))
        #expect(!earlier.day.contains("2026"))
        #expect(!earlier.day.isEmpty)
        #expect(HistoryTable.when(of: date(2025, 12, 28, 9, 5), now: now).day.contains("2025"))
    }

    @Test("A mention shows what was heard, and its details show the excerpt, else the context")
    func historyDetails() {
        let hits = DemoFixtures.historyHits
        #expect(HistoryTable.heard(by: hits[2]) == "Bhala")
        #expect(HistoryTable.heard(by: Hit(
            ruleID: UUID(), ruleName: "r", term: "Bala", matchedText: "  ", context: "c", timestamp: Date(),
            source: .microphone, engine: .appleSFSpeech, segmentID: "s")) == "Bala")

        #expect(HistoryDetail.title(for: hits[0]) == "What was said")
        #expect(HistoryDetail.title(for: hits[2]) == "Around the mention")
        // A blank excerpt counts as none.
        var blank = hits[2]
        blank.excerpt = "  \n"
        #expect(HistoryDetail.excerpt(of: blank) == nil)

        // The heard words are marked in the excerpt, wherever they stand as a word.
        #expect(MatchTesterView.markedParts(of: HistoryDetail.marked(hits[0])) == ["Bala"])
        // What was heard ("Bhala"), not the rule's word, is what is in the context.
        #expect(MatchTesterView.markedParts(of: HistoryDetail.marked(hits[2])) == ["Bhala"])
        #expect(MatchTesterView.markedParts(of: HistoryDetail.marked(hits[4])) == ["Bala Kumar"])
    }

    @Test("Mentions are counted and the setting explained in plain words")
    func historyWords() {
        #expect(HistorySettingsView.count(of: 0) == "No mentions")
        #expect(HistorySettingsView.count(of: 1) == "1 mention")
        #expect(HistorySettingsView.count(of: 5) == "5 mentions")
        #expect(HistorySettingsView.explanation(isKept: true).contains("500"))
        #expect(HistorySettingsView.explanation(isKept: false) == "Nothing new is saved while this is off.")
        #expect(HistoryTable.emptyMessage == "Nothing yet. When someone says one of your keywords it shows up here.")
    }

    @Test("The history window and the pane read what the controller kept, and clearing empties it")
    func historyIsRead() async {
        let hits = DemoFixtures.historyHits
        let controller = await SettingsFixtures.controller(history: hits)
        let read = await controller.history()
        #expect(read.map(\.id) == hits.map(\.id))
        #expect(read[0].excerpt == hits[0].excerpt)
        await controller.clearHistory()
        #expect(await controller.history().isEmpty)
    }

    // MARK: Marking words

    @Test("Words are marked only where they stand as a word of their own")
    func occurrences() {
        let text = "Balance, bala! thanks Bala. Bálá and Balakumar"
        let found = TextHighlighting.occurrences(of: "Bala", in: text).map { String(text[$0]) }
        #expect(found == ["bala", "Bala", "Bálá"])
        #expect(TextHighlighting.occurrences(of: "  ", in: text).isEmpty)
        #expect(TextHighlighting.occurrences(of: "Bala", in: "").isEmpty)
    }

    @Test("Marking a text uses the rules that are on")
    func highlighting() {
        let on = Rule(name: "Name", terms: ["Bala"])
        let standup = Rule(name: "Standup", terms: ["standup"])
        var off = standup
        off.isEnabled = false
        let text = "Bala said the standup moves"
        let both = TextHighlighting.highlighted(text, rules: [on, standup])
        #expect(MatchTesterView.markedParts(of: both) == ["Bala", "standup"])
        #expect(String(both.characters) == text)
        #expect(MatchTesterView.markedParts(of: TextHighlighting.highlighted(text, rules: [on, off])) == ["Bala"])
        #expect(MatchTesterView.markedParts(of: TextHighlighting.highlighted(text, rules: [])).isEmpty)
    }

    // MARK: Live transcript

    /// The controller's windows over `text`, from `start` on: the last 300 characters after every `step` characters.
    private func windows(of text: String, step: Int, from start: Int = 40) -> [String] {
        var windows: [String] = []
        var end = start
        while end < text.count {
            windows.append(String(text.prefix(end).suffix(LiveTranscriptBuffer.windowLimit)))
            end += step
        }
        windows.append(String(text.suffix(LiveTranscriptBuffer.windowLimit)))
        return windows
    }

    @Test("The live buffer follows the controller's window as it grows, slides and is revised")
    func liveBufferFollows() {
        let text = DemoFixtures.longTranscript
        for step in [1, 7, 17, 41, 120] {
            var buffer = LiveTranscriptBuffer()
            for window in windows(of: text, step: step) {
                buffer.take(window)
                #expect(buffer.text.hasSuffix(window.trimmingCharacters(in: .whitespaces)), "step \(step)")
            }
            #expect(buffer.text == text, "step \(step) put the whole text together")
        }
    }

    @Test("The live buffer takes the engine's changes to the words it is working on")
    func liveBufferRevisions() {
        var buffer = LiveTranscriptBuffer()
        buffer.take("okay so let's")
        buffer.take("okay so let's start")
        #expect(buffer.text == "okay so let's start")
        // The first words change as they are finished: capital, comma.
        buffer.take("Okay, so let's start with")
        #expect(buffer.text == "Okay, so let's start with")
        buffer.take("Okay, so let's start with the numbers.")
        #expect(buffer.text == "Okay, so let's start with the numbers.")

        // A longer text: the last words are changed, the earlier ones stay.
        var longer = LiveTranscriptBuffer(seed: DemoFixtures.longTranscript)
        let before = longer.text
        var window = DemoFixtures.liveWindow
        window.removeLast(" plan.".count)
        window += " plant"
        longer.take(window)
        #expect(longer.text.hasPrefix(String(before.dropLast(" plan.".count + 40))))
        #expect(longer.text.hasSuffix("launch plant"))
        #expect(longer.text.count == before.count)  // " plan." became " plant"

        // The same window again changes nothing. An empty one keeps what is there and starts a new line.
        longer.take(window)
        #expect(longer.text.count == before.count)
        longer.take("   ")
        #expect(longer.text.hasSuffix("launch plant\n"))
    }

    @Test("A restart begins a new line, and words after a gap follow with a space")
    func liveBufferRuns() {
        var buffer = LiveTranscriptBuffer()
        buffer.take("first run of words")
        buffer.take("")
        buffer.take("second run")
        #expect(buffer.text == "first run of words\nsecond run")

        // 300 characters that do not start in the last window: a gap.
        var gapped = LiveTranscriptBuffer()
        let one = String(repeating: "alpha beta ", count: 28)
        let two = String(repeating: "gamma delta ", count: 26)
        gapped.take(one)
        gapped.take(two)
        #expect(gapped.text == one.trimmingCharacters(in: .whitespaces) + " " + two.trimmingCharacters(in: .whitespaces))
    }

    @Test("The live buffer keeps 2 000 characters and starts at a word")
    func liveBufferLimit() {
        let sentence = "the quick brown fox jumps over the lazy dog "
        let text = String(repeating: sentence, count: 120).trimmingCharacters(in: .whitespaces)  // 5 300 characters
        var buffer = LiveTranscriptBuffer()
        for window in windows(of: text, step: 29) { buffer.take(window) }
        #expect(buffer.text.count <= LiveTranscriptBuffer.limit)
        #expect(buffer.text.count > LiveTranscriptBuffer.limit - 60)
        #expect(buffer.text.hasSuffix("lazy dog"))
        let firstWord = String(buffer.text.prefix { !$0.isWhitespace })
        #expect(sentence.split(separator: " ").map(String.init).contains(firstWord), "starts mid-word: \(firstWord)")
        #expect(text.hasSuffix(buffer.text))
    }

    @Test("A phrase that comes twice in the window does not make the buffer lose its place")
    func liveBufferRepeatedPhrase() {
        let phrase = "we should check the numbers for this quarter"
        let text =
            "First \(phrase) before the review starts tomorrow morning, and make sure the finance team has seen them. "
            + "Later on, after lunch and the long design sync, \(phrase) again with finance so nothing is missed in the "
            + "report that goes out on Friday afternoon. Then \(phrase) one more time with the whole group, because the "
            + "last time somebody changed a column and nobody noticed until the board meeting, which was not great at all. "
            + "So this time everybody reads the sheet before the call, the owners say what changed since the last "
            + "version, and we write down every open question in the notes so that nothing waits for the next review."
        #expect(text.count > 2 * LiveTranscriptBuffer.windowLimit)
        for step in [3, 11, 37, 90] {
            var buffer = LiveTranscriptBuffer()
            for window in windows(of: text, step: step) { buffer.take(window) }
            #expect(buffer.text == text, "step \(step)")
        }
    }

    @Test("The live window says what it shows, and the last mention is titled with its time and rule")
    func liveWords() {
        #expect(LiveTranscriptWindow.privacyNote == "Nothing here is saved.")
        #expect(LiveHeader.details(for: .off, active: nil, configuration: DemoFixtures.configuration) == "System audio")
        #expect(LiveHeader.details(for: .listening(DemoFixtures.listeningInfo), active: .appleSpeechTranscriber,
            configuration: DemoFixtures.configuration).hasPrefix("Apple Speech (on-device) · "))
        #expect(LiveHeader.details(for: .preparing(.downloadingModel(0.4)), active: nil, configuration: DemoFixtures.configuration)
            == "Local model · Light")
        let now = DemoFixtures.today(12, 0)
        #expect(LiveTranscriptWindow.lastMentionTitle(for: DemoFixtures.historyHits[0], now: now)
            == "Last mention, \(DemoFixtures.today(10, 32).formatted(date: .omitted, time: .shortened)) · My name")
    }

    // MARK: Shortcuts and API

    @Test("Every link the pane lists is a route the app reads, and every route is listed")
    func routesAreReal() {
        var kinds: Set<String> = []
        for route in APIReference.routes {
            guard let url = URL(string: route.url), let parsed = URLRoute(url: url) else {
                Issue.record("\(route.url) is not a route")
                continue
            }
            kinds.insert(String(describing: parsed).split(separator: "(").first.map(String.init) ?? "")
            #expect(!route.summary.isEmpty)
        }
        let expected: Set<String> = ["start", "pause", "toggle", "resume", "snooze", "openSettings", "openHistory", "openLive"]
        #expect(kinds == expected)
        // The example snooze link uses the default length, so it reads back as that.
        #expect(URLRoute(url: URL(string: "takeheed://snooze?minutes=30")!) == .snooze(minutes: 30))
    }

    @Test("The Shortcuts actions are the eight the spec lists")
    func shortcutActions() {
        #expect(APIReference.shortcutActions.map(\.name) == [
            "Start Listening", "Pause Listening", "Toggle Listening", "Snooze Alerts", "Add Keyword",
            "Set Rule Enabled", "Get Recent Hits", "Get Status",
        ])
        #expect(APIReference.shortcutActions.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("The example body is valid JSON with the keys the app really sends")
    func payloadExampleMatchesTheApp() throws {
        let example = APIReference.payloadExample(version: "1.0.0", build: "123")
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])

        let hit = Hit(
            ruleID: UUID(), ruleName: "My name", term: "Bala", matchedText: "Bala", context: "…can Bala share the deck…",
            timestamp: Date(timeIntervalSince1970: 1_760_175_000), source: .systemAudio, engine: .appleSpeechTranscriber,
            segmentID: "s1", excerpt: "…what do you think, Bala, can you share the deck…")
        let real = try #require(
            JSONSerialization.jsonObject(
                with: WebhookPayload.body(for: hit, event: "keyword.detected", appVersion: "1.0.0", build: "123"))
                as? [String: Any])
        let keys = { (value: Any?) -> Set<String> in Set((value as? [String: Any])?.keys.map { $0 } ?? []) }
        #expect(Set(parsed.keys) == Set(real.keys))
        #expect(keys(parsed["rule"]) == keys(real["rule"]))
        #expect(keys(parsed["app"]) == keys(real["app"]))
        #expect(!keys(parsed["rule"]).isEmpty)
        #expect(parsed["event"] as? String == real["event"] as? String)
        #expect(parsed["version"] as? Int == real["version"] as? Int)
        #expect(parsed["source"] as? String == real["source"] as? String)
        #expect(parsed["engine"] as? String == real["engine"] as? String)
        #expect((parsed["app"] as? [String: String])?["version"] == "1.0.0")
    }

    @Test("The signature check the pane describes gives the signature the app sends")
    func signatureSnippetMatchesTheApp() throws {
        #expect(APIReference.signatureSnippet == """
            expected = hex(HMAC_SHA256(secret, t + "." + raw_body))
            compare with the v1 value in X-NameAlert-Signature
            """)
        let body = Data(#"{"event":"keyword.detected"}"#.utf8)
        let secret = "s3cret"
        let t = 1_760_175_000
        // The check, as the snippet words it.
        var message = Data("\(t).".utf8)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        let header = WebhookPayload.signatureHeader(body: body, secret: secret, timestamp: t)
        #expect(header == "t=\(t),v1=\(expected)")
        #expect(APIReference.requestExample(version: "1.0.0").contains("X-NameAlert-Signature: t="))
        #expect(APIReference.requestExample(version: "1.0.0").contains("User-Agent: NameAlert/1.0.0"))
    }

    // MARK: About

    @Test("About names the version, links to the site and keeps its privacy line")
    func aboutWords() {
        #expect(AboutSettingsView.versionLine(version: "1.0.0", build: "123") == "Version 1.0.0 (123)")
        #expect(AboutSettingsView.privacySummary
            == "Audio never leaves this Mac. The words around a mention leave only if you set up ntfy, a Telegram call or a webhook — and only to the service you chose.")
        #expect(AboutLinks.support.absoluteString == "https://balakumardev.github.io/NameAlert/support.html")
        #expect(AboutLinks.privacy.absoluteString == "https://balakumardev.github.io/NameAlert/privacy.html")
        #expect(AboutLinks.support.scheme == "https")
    }

    @Test("The acknowledgements hold every notice, a heading each, and ship in the app")
    func acknowledgements() throws {
        let text = AboutLinks.acknowledgements()
        #expect(!text.contains("could not be loaded"), "Acknowledgements.txt is not in the app's resources")
        let headings = text.split(separator: "\n").filter {
            $0.hasPrefix("whisper.cpp and ggml") || $0.hasPrefix("Whisper model weights")
                || $0.hasPrefix("Silero VAD") || $0.hasPrefix("SCOWL word lists")
        }
        #expect(headings.count == 4)
        #expect(text.contains("Permission is hereby granted, free of charge"))
        #expect(text.contains("Copyright (c) 2023-2026 The ggml authors"))
        // The model weights and the voice detector the app downloads come with their notices.
        #expect(text.contains("Copyright (c) 2022 OpenAI"))
        #expect(text.contains("Copyright (c) 2020-present Silero Team"))
        #expect(text.contains("Kevin Atkinson"))
        // The SCOWL notice is the one the package ships, word for word.
        let scowl = try String(
            contentsOf: RenderHarness.repositoryRoot
                .appendingPathComponent("Packages/NameAlertKit/Sources/NameAlertCore/Resources/SCOWL-LICENSE.txt"),
            encoding: .utf8)
        #expect(text.contains(scowl))
        #expect(AboutLinks.acknowledgements(in: Bundle(for: PlaceholderClass.self)).contains("could not be loaded"))
    }

    @Test("Run Setup Again marks setup as not done and opens it")
    func runSetupAgain() async {
        let controller = DemoFixtures.controller(.off)
        let router = WindowRouter()
        #expect(controller.configuration.hasCompletedOnboarding)
        AboutSettingsView.runSetupAgain(controller: controller, router: router)
        await controller.finishPendingEdits()
        #expect(!controller.configuration.hasCompletedOnboarding)
        #expect(router.takePending() == .onboarding)
        #expect(controller.configuration.rules.count == 2, "The rules stay")
    }

    // MARK: Diagnostics

    private func snapshot(_ configuration: AppConfiguration, log: [String] = ["a line"]) -> Diagnostics.Snapshot {
        Diagnostics.Snapshot(
            appName: "Takeheed", version: "1.0.0", build: "42", macOS: "26.0.1", architecture: "arm64",
            date: Date(timeIntervalSince1970: 1_760_175_000), state: "Listening · System audio",
            engine: "Apple Speech (on-device), en-US",
            permissions: PermissionsSnapshot(
                microphone: .granted, screenRecording: .denied, speechRecognition: .notDetermined, notifications: .granted),
            warnings: ["local model falling behind"], installedModels: ["vad.silero", "whisper.light.en"],
            configuration: configuration, log: log)
    }

    @Test("The report names the version, the Mac, the state and the set-up in counts")
    func diagnosticsReport() {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.channels.webhook.url = "https://hooks.example.com/very-secret-path"
        configuration.channels.ntfy.topic = "my-private-topic"
        let text = Diagnostics.format(snapshot(configuration))
        #expect(text.hasPrefix("Takeheed 1.0.0 (42)\nmacOS 26.0.1, arm64\nDate: 2025-10-11T"))
        #expect(text.contains("State: Listening · System audio"))
        #expect(text.contains("Speech engine: Apple Speech (on-device), en-US"))
        #expect(text.contains("Permissions: Microphone allowed, Screen Recording denied, Speech Recognition not decided, Notifications allowed"))
        #expect(text.contains("Warnings: local model falling behind"))
        #expect(text.contains("Models on this Mac: vad.silero, whisper.light.en"))
        #expect(text.contains("Rules: 3 (2 on), 6 words in all"))
        #expect(text.contains("Alerts the rules use: Sound 2, Notification 2, Alarm until dismissed 1"))
        #expect(text.contains("Alerts set up: ntfy push yes, Telegram call no, Webhook yes"))
        #expect(text.contains("Wait between any two alerts: 3 s"))
        #expect(text.contains("Log, this run (1 lines)\n  a line"))
    }

    @Test("The report leaves out every word, name, address and secret of the set-up")
    func diagnosticsLeavesThingsOut() {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.rules = [Rule(name: "Sensitive Rule Name", terms: ["Secretterm", "Another Secret"])]
        configuration.channels.webhook.url = "https://hooks.example.com/very-secret-path"
        configuration.channels.webhook.headerNames = ["X-Secret-Header"]
        configuration.channels.ntfy.topic = "my-private-topic"
        configuration.channels.ntfy.server = "https://ntfy.private.example"
        configuration.channels.telegramCall.user = "@private_user"
        configuration.channels.telegramCall.messageTemplate = "private template {context}"
        configuration.speech.localeIdentifier = "de-DE"
        let text = Diagnostics.format(snapshot(configuration))
        for secret in [
            "Sensitive", "Secretterm", "Another Secret", "hooks.example.com", "very-secret-path", "X-Secret-Header",
            "my-private-topic", "ntfy.private.example", "private_user", "private template",
        ] {
            #expect(!text.contains(secret), "The report holds \(secret)")
        }
        #expect(text.contains("Rules: 1 (1 on), 2 words in all"))
        #expect(text.contains("language de-DE"))
    }

    @Test("The log lines are this run's info and error lines; heard text and debug lines stay out")
    func diagnosticsLog() async {
        let logger = Log.logger("diagnostics-test")
        let marker = String(UUID().uuidString.prefix(8))
        logger.info("Diagnostics test line \(marker, privacy: .public)")
        logger.error("Diagnostics test failure \(marker, privacy: .public): \("TRANSCRIPT-WORDS", privacy: .private)")
        logger.debug("Diagnostics test debug \(marker, privacy: .public) \("TRANSCRIPT-WORDS", privacy: .private)")
        var lines: [String] = []
        for _ in 0..<40 {
            lines = await Diagnostics.logLines(limit: 500).filter { $0.contains(marker) }
            if lines.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(lines.count == 2, "\(lines)")
        #expect(lines.contains { $0.contains(" info [diagnostics-test] Diagnostics test line \(marker)") })
        #expect(lines.contains { $0.contains(" error [diagnostics-test] Diagnostics test failure \(marker)") })
        // Debug lines, the only place heard text is logged, are not in the report at all.
        #expect(!lines.contains { $0.contains("debug") })
        // A private value reads as "<private>" in the log store, as it does for the app on any Mac that is not being
        // debugged. A test run launched by Xcode shows private values (OS_ACTIVITY_DT_MODE), so say nothing there.
        if ProcessInfo.processInfo.environment["OS_ACTIVITY_DT_MODE"] == nil {
            #expect(lines.contains { $0.hasSuffix("Diagnostics test failure \(marker): <private>") })
            #expect(!lines.joined().contains("TRANSCRIPT-WORDS"))
        }

        let line = Diagnostics.logLine(
            date: Date(timeIntervalSince1970: 1_760_175_000), tag: "info", category: "x",
            message: "two\nlines " + String(repeating: "a", count: 500))
        #expect(line.hasPrefix("2025-10-11T"))
        #expect(!line.contains("\n"))
        #expect(line.hasSuffix("…"))
        #expect(line.count < 460)
    }

    @Test("A report is made from the controller and says what it is doing")
    func diagnosticsFromController() async {
        let controller = DemoFixtures.controller(
            .listening(DemoFixtures.listeningInfo), hits: DemoFixtures.hits, transcript: "heard words", level: 0.2)
        let report = await Diagnostics.report(for: controller)
        #expect(report.contains("State: Listening · System audio"))
        #expect(report.contains("Speech engine: Apple Speech (on-device), en-US"))
        #expect(report.contains("Rules: 2 (2 on), 2 words in all"))
        #expect(!report.contains("heard words"))
        #expect(!report.contains("Bala"))
        #expect(!report.contains("My name"))
        #expect(report.contains("Log, this run ("))
    }
}

/// A class in this bundle, to point at a bundle that has no acknowledgements.
private final class PlaceholderClass {}
