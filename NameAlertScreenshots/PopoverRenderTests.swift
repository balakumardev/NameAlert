import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

@Suite("Popover renders", .serialized)
@MainActor
struct PopoverRenderTests {
    enum Scenario: String, CaseIterable, Sendable {
        case listening, off, snoozed, errorPermission = "error-permission", downloading
    }

    @Test("The popover renders every state at 340 pt", arguments: Scenario.allCases, [false, true])
    func popover(_ scenario: Scenario, dark: Bool) throws {
        let popover = MenuBarPopover()
            .environment(Self.controller(for: scenario))
            .environment(WindowRouter())
        let size = RenderHarness.fittingSize(of: popover, width: nil)
        #expect(size.width == MenuBarPopover.width)
        #expect(size.height < 520, "The popover should fit comfortably under the menu bar")
        let name = "popover-\(scenario.rawValue)" + (dark ? "-dark" : "")
        let url = try RenderHarness.render(PopoverRenderFrame { popover }, name: name, appearance: dark ? .darkAqua : .aqua)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Every problem and warning note fits at 340 pt", arguments: [false, true])
    func notices(dark: Bool) throws {
        let sheet = NoticesSheet()
            .environment(DemoFixtures.controller(.off))
            .environment(WindowRouter())
        try RenderHarness.render(
            PopoverRenderFrame { sheet }, name: "popover-notices" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("Rows show their hover highlight", arguments: [false, true])
    func rowHighlight(dark: Bool) throws {
        try RenderHarness.render(
            PopoverRenderFrame { RowStatesSheet() }, name: "popover-row-hover" + (dark ? "-dark" : ""),
            appearance: dark ? .darkAqua : .aqua)
    }

    @Test("The new keyword field renders")
    func addingKeyword() throws {
        let popover = MenuBarPopover(isAddingKeyword: true)
            .environment(DemoFixtures.controller(.off))
            .environment(WindowRouter())
        try RenderHarness.render(PopoverRenderFrame { popover }, name: "popover-adding-keyword")
    }

    static func controller(for scenario: Scenario) -> ListeningController {
        switch scenario {
        case .listening:
            DemoFixtures.controller(
                .listening(DemoFixtures.listeningInfo), hits: DemoFixtures.hits, transcript: DemoFixtures.transcript,
                level: 0.35)
        case .off:
            DemoFixtures.controller(.off)
        case .snoozed:
            DemoFixtures.controller(.snoozed(until: DemoFixtures.today(10, 45)), hits: DemoFixtures.hits)
        case .errorPermission:
            DemoFixtures.controller(.error(.permissionDenied(.screenRecording)), hits: Array(DemoFixtures.hits.prefix(2)))
        case .downloading:
            DemoFixtures.controller(.preparing(.downloadingModel(0.45)), configuration: Self.localModelConfiguration)
        }
    }

    static var localModelConfiguration: AppConfiguration {
        var configuration = DemoFixtures.configuration
        configuration.speech.engine = .localModel
        return configuration
    }
}

/// Every problem's note with its fix, and both warnings, at the popover's width.
private struct NoticesSheet: View {
    static let issues: [ListeningIssue] = [
        .permissionDenied(.screenRecording),
        .permissionDenied(.microphone),
        .permissionDenied(.speechRecognition),
        .engineUnavailable("Speech recognition isn't available for de-DE on this Mac."),
        .modelMissing,
        .captureFailed("No microphone is connected."),
        .engineFailed("The speech engine stopped unexpectedly."),
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.issues.indices, id: \.self) { index in
                IssueNotice(issue: Self.issues[index])
            }
            ForEach(PopoverNotices.warningOrder, id: \.self) { warning in
                WarningNotice(warning: warning)
            }
        }
        .padding(8)
        .frame(width: MenuBarPopover.width)
    }
}

/// Hit rows and footer buttons as the popover draws them, the second of each under the pointer.
private struct RowStatesSheet: View {
    var body: some View {
        VStack(spacing: 0) {
            let hits = DemoFixtures.hits
            ForEach(Array(hits.prefix(2).enumerated()), id: \.offset) { index, hit in
                Button {} label: { HitRow(hit: hit) }
                    .buttonStyle(RowButtonStyle(isHighlighted: index == 1))
            }
            Divider().padding(.horizontal, 4).padding(.vertical, 8)
            HStack(spacing: 4) {
                Button("Settings…") {}.buttonStyle(RowButtonStyle())
                Button("History…") {}.buttonStyle(RowButtonStyle(isHighlighted: true))
                Spacer()
            }
        }
        .padding(8)
        .frame(width: MenuBarPopover.width)
    }
}

/// Shows a popover as the menu bar does: drawn as the key window (the open popover is key, the offscreen render
/// window is not), on the window background (renders cannot capture the real window's material), with rounded
/// corners and a hairline edge, on a plain backdrop.
struct PopoverRenderFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .padding(16)
            .background(Color(nsColor: .underPageBackgroundColor))
    }
}

@Suite("Popover copy and logic")
@MainActor
struct PopoverLogicTests {
    @Test("Status lines read as the spec words them")
    func statusLines() {
        #expect(StatusText.title(for: .off) == "Paused")
        #expect(StatusText.title(for: .listening(DemoFixtures.listeningInfo)) == "Listening · System audio")
        #expect(StatusText.title(for: .waitingForCall) == "Waiting for a call")
        #expect(StatusText.title(for: .preparing(.starting)) == "Starting…")
        #expect(StatusText.title(for: .preparing(.permissions)) == "Starting…")
        let downloading = StatusText.title(for: .preparing(.downloadingModel(0.45)))
        #expect(downloading.hasPrefix("Downloading speech model… ") && downloading.contains("45"))
        let installing = StatusText.title(for: .preparing(.installingAppleAssets(0.3)))
        #expect(installing.hasPrefix("Preparing Apple speech… ") && installing.contains("30"))
        #expect(StatusText.title(for: .error(.permissionDenied(.screenRecording))) == "Screen Recording is off")
    }

    @Test("A snooze names its end time, and the day when it is not today")
    func snoozeTimes() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let later = now.addingTimeInterval(105 * 60)
        #expect(StatusText.title(for: .snoozed(until: later), now: now)
            == "Snoozed until \(later.formatted(date: .omitted, time: .shortened))")
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        #expect(StatusText.title(for: .snoozed(until: tomorrow), now: now)
            == "Snoozed until tomorrow \(tomorrow.formatted(date: .omitted, time: .shortened))")
    }

    @Test("Engines are named as the spec words them")
    func engineNames() {
        #expect(StatusText.engineName(.appleSpeechTranscriber) == "Apple Speech (on-device)")
        #expect(StatusText.engineName(.appleDictationTranscriber) == "Apple Dictation (on-device)")
        #expect(StatusText.engineName(.appleSFSpeech) == "Apple Speech (on-device, older model)")
        #expect(StatusText.engineName(.whisperLight) == "Local model · Light")
        #expect(StatusText.engineName(.whisperBalanced) == "Local model · Balanced")
    }

    @Test("The header names the engine, and the local model while it downloads")
    func headerEngine() {
        let configuration = DemoFixtures.configuration
        #expect(PopoverHeader.engine(for: .listening(DemoFixtures.listeningInfo), active: nil, configuration: configuration)
            == .appleSpeechTranscriber)
        #expect(PopoverHeader.engine(for: .preparing(.downloadingModel(0.2)), active: nil, configuration: configuration)
            == .whisperLight)
        #expect(PopoverHeader.engine(for: .off, active: .whisperLight, configuration: configuration) == nil)
        #expect(PopoverHeader.togglePauses(.snoozed(until: Date())))
        #expect(!PopoverHeader.togglePauses(.error(.modelMissing)))
    }

    @Test("Each problem gets the fix the spec asks for")
    func issueFixes() {
        #expect(IssueFix(issue: .permissionDenied(.microphone), enginePreference: .automatic)
            == .openSystemSettings(.microphone))
        #expect(IssueFix(issue: .engineUnavailable("x"), enginePreference: .automatic) == .useLocalModel)
        #expect(IssueFix(issue: .engineUnavailable("x"), enginePreference: .localModel) == .tryAgain)
        #expect(IssueFix(issue: .captureFailed("x"), enginePreference: .apple) == .tryAgain)
        #expect(IssueFix(issue: .modelMissing, enginePreference: .localModel) == .tryAgain)
        // Screen Recording granted but not yet visible to this process: relaunch, and say it once.
        let relaunch: Set<RuntimeWarning> = [.screenRecordingNeedsRelaunch, .localModelFallingBehind]
        #expect(IssueFix(issue: .permissionDenied(.screenRecording), enginePreference: .automatic, warnings: relaunch)
            == .relaunch)
        #expect(IssueFix(issue: .permissionDenied(.microphone), enginePreference: .automatic, warnings: relaunch)
            == .openSystemSettings(.microphone))
        #expect(PopoverNotices.warnings(besides: .permissionDenied(.screenRecording), in: relaunch)
            == [.localModelFallingBehind])
        #expect(PopoverNotices.warnings(besides: nil, in: relaunch)
            == [.screenRecordingNeedsRelaunch, .localModelFallingBehind])
        for permission in PermissionKind.allCases {
            #expect(SystemSettingsLink.url(for: permission) != nil)
        }
    }

    @Test("The live strip shows the end of the transcript from a word start")
    func liveSnippet() {
        #expect(LiveStrip.snippet(of: "  hello   there ") == "hello there")
        let snippet = LiveStrip.snippet(of: DemoFixtures.transcript)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.count <= LiveStrip.snippetLength + 1)
        #expect(DemoFixtures.transcript.hasSuffix(String(snippet.dropFirst())))
        #expect(!snippet.dropFirst().hasPrefix(" "))
    }

    @Test("A hit's context starts a few words before what was heard")
    func focusedContext() {
        let hit = DemoFixtures.hits[0]
        #expect(HitRow.focusedContext(of: hit)
            == "…up, can Bala share the screen with the latest numbers…")
        let short = DemoFixtures.hit(DemoFixtures.nameRule, "Bala", "hi Bala", at: Date())
        #expect(HitRow.focusedContext(of: short) == short.context)
    }

    @Test("Until tomorrow 9:00 counts the minutes to the next 9:00")
    func snoozeUntilMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 22, minute: 30)))
        #expect(SnoozeChoice.minutesUntilMorning(after: evening, calendar: calendar) == 630)
        #expect(SnoozeChoice.untilMorningTitle(now: evening, calendar: calendar).hasPrefix("Until tomorrow "))
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 7, minute: 15)))
        #expect(SnoozeChoice.minutesUntilMorning(after: early, calendar: calendar) == 105)
        #expect(!SnoozeChoice.untilMorningTitle(now: early, calendar: calendar).contains("tomorrow"))
        let nine = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9)))
        #expect(SnoozeChoice.minutesUntilMorning(after: nine, calendar: calendar) == 24 * 60)
    }

    @Test("A typed keyword is trimmed; blank text is not a keyword")
    func keywords() {
        #expect(PopoverActions.keyword(from: "  Bala   Kumar ") == "Bala Kumar")
        #expect(PopoverActions.keyword(from: " \n ") == nil)
    }
}
