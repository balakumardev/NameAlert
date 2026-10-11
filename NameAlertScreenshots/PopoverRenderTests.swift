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
        case listening, off, snoozed, errorPermission = "error-permission", errorRefused = "error-refused", downloading
        case notificationsOff = "notifications-off"
    }

    /// Nothing decided yet: every permission has not been asked for.
    static let undecided = PermissionsSnapshot(
        microphone: .notDetermined, screenRecording: .notDetermined, speechRecognition: .notDetermined,
        notifications: .notDetermined)

    @Test("The popover renders every state at 340 pt", arguments: Scenario.allCases, [false, true])
    func popover(_ scenario: Scenario, dark: Bool) async throws {
        let controller = await Self.controller(for: scenario)
        switch scenario {
        case .errorPermission: #expect(controller.state == .error(.permissionDenied(.screenRecording)))
        case .errorRefused: #expect(controller.state == .error(.permissionDenied(.microphone)))
        default: break
        }
        let popover = MenuBarPopover()
            .environment(controller)
            .environment(WindowRouter())
        let size = RenderHarness.fittingSize(of: popover, width: nil)
        #expect(size.width == MenuBarPopover.width)
        #expect(size.height < 520, "The popover should fit comfortably under the menu bar")
        let name = "popover-\(scenario.rawValue)" + (dark ? "-dark" : "")
        let url = try RenderHarness.render(PopoverRenderFrame { popover }, name: name, appearance: dark ? .darkAqua : .aqua)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Every problem and warning note fits at 340 pt, asking for what was not asked for yet", arguments: [false, true])
    func notices(dark: Bool) async throws {
        let controller = await SettingsFixtures.controller(permissions: Self.undecided)
        try withScratchAsks { asks in
            let sheet = NoticesSheet(asks: asks)
                .environment(controller)
                .environment(WindowRouter())
            try RenderHarness.render(
                PopoverRenderFrame { sheet }, name: "popover-notices" + (dark ? "-dark" : ""),
                appearance: dark ? .darkAqua : .aqua)
        }
    }

    @Test("The same notes send to System Settings once each permission was asked for", arguments: [false, true])
    func noticesAfterAsking(dark: Bool) async throws {
        let controller = await SettingsFixtures.controller(permissions: Self.undecided)
        try withScratchAsks(asked: PermissionKind.allCases) { asks in
            let sheet = NoticesSheet(asks: asks)
                .environment(controller)
                .environment(WindowRouter())
            try RenderHarness.render(
                PopoverRenderFrame { sheet }, name: "popover-notices-asked" + (dark ? "-dark" : ""),
                appearance: dark ? .darkAqua : .aqua)
        }
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

    static func controller(for scenario: Scenario) async -> ListeningController {
        switch scenario {
        case .listening:
            return DemoFixtures.controller(
                .listening(DemoFixtures.listeningInfo), hits: DemoFixtures.hits, transcript: DemoFixtures.transcript,
                level: 0.35)
        case .off:
            return DemoFixtures.controller(.off)
        case .snoozed:
            return DemoFixtures.controller(.snoozed(until: DemoFixtures.today(10, 45)), hits: DemoFixtures.hits)
        case .errorPermission:
            // Screen Recording was never asked for, and macOS reports it as "not decided" whatever happened: Allow…
            return await failedStart(
                source: .systemAudio,
                permissions: PermissionsSnapshot(
                    microphone: .granted, screenRecording: .notDetermined, speechRecognition: .granted,
                    notifications: .granted),
                finding: .permissionDenied(.screenRecording))
        case .errorRefused:
            // The microphone was refused, and so were notifications: System Settings is the only way.
            return await failedStart(
                source: .microphone,
                permissions: PermissionsSnapshot(
                    microphone: .denied, screenRecording: .granted, speechRecognition: .granted, notifications: .denied),
                finding: .permissionDenied(.microphone))
        case .downloading:
            return DemoFixtures.controller(
                .preparing(.downloadingModel(0.45)), configuration: Self.localModelConfiguration)
        case .notificationsOff:
            // Everything allowed but notifications, which were never asked for, while rules notify.
            return await SettingsFixtures.controller(
                permissions: PermissionsSnapshot(
                    microphone: .granted, screenRecording: .granted, speechRecognition: .granted,
                    notifications: .notDetermined),
                history: DemoFixtures.hits)
        }
    }

    /// A controller on the stand-ins whose first attempt to listen found `issue`: it is in that error state.
    static func failedStart(
        source: AudioSourceKind, permissions: PermissionsSnapshot, finding issue: ListeningIssue,
        configuration base: AppConfiguration = DemoFixtures.configuration
    ) async -> ListeningController {
        var configuration = base
        configuration.listening.source = source
        let controller = await SettingsFixtures.controller(
            configuration: configuration, permissions: permissions, history: Array(DemoFixtures.hits.prefix(2)))
        await controller.start()
        // The attempt that finds the permission missing runs in the background: wait for its result.
        for _ in 0..<150 where controller.state != .error(issue) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return controller
    }

    static var localModelConfiguration: AppConfiguration {
        var configuration = DemoFixtures.configuration
        configuration.speech.engine = .localModel
        return configuration
    }
}

/// Every problem's note with its fix, both warnings and the notifications note, at the popover's width. `asks` says
/// which permissions were asked for already.
private struct NoticesSheet: View {
    let asks: PermissionAsks

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
                IssueNotice(issue: Self.issues[index], asks: asks)
            }
            ForEach(PopoverNotices.warningOrder, id: \.self) { warning in
                WarningNotice(warning: warning)
            }
            NotificationsOffNotice(asks: asks)
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

    @Test("A permission that was not asked for yet is asked for; after that, or once refused, System Settings is the way")
    func permissionFixes() {
        let neverAsked = PermissionsSnapshot(
            microphone: .notDetermined, screenRecording: .notDetermined, speechRecognition: .notDetermined,
            notifications: .notDetermined)
        let notYet: (PermissionKind) -> Bool = { _ in false }
        for permission in [PermissionKind.microphone, .screenRecording, .speechRecognition] {
            #expect(
                IssueFix(
                    issue: .permissionDenied(permission), enginePreference: .automatic, permissions: neverAsked,
                    hasAsked: notYet) == .allow(permission))
            // Asked for already: the system will not ask again.
            #expect(
                IssueFix(
                    issue: .permissionDenied(permission), enginePreference: .automatic, permissions: neverAsked,
                    hasAsked: { $0 == permission }) == .openSystemSettings(permission))
        }
        // Only the one that was asked for is changed: the others are still asked for.
        #expect(
            IssueFix(
                issue: .permissionDenied(.microphone), enginePreference: .automatic, permissions: neverAsked,
                hasAsked: { $0 == .screenRecording }) == .allow(.microphone))
        // Refused: never asked again, whatever was remembered.
        var refused = neverAsked
        refused.microphone = .denied
        #expect(
            IssueFix(
                issue: .permissionDenied(.microphone), enginePreference: .automatic, permissions: refused,
                hasAsked: notYet) == .openSystemSettings(.microphone))
        // Allowed by the time the note is read: try again.
        var allowed = neverAsked
        allowed.microphone = .granted
        #expect(
            IssueFix(
                issue: .permissionDenied(.microphone), enginePreference: .automatic, permissions: allowed,
                hasAsked: notYet) == .tryAgain)
        // Allowed but only a new process can use it: relaunch comes before asking.
        var screenAllowed = neverAsked
        screenAllowed.screenRecording = .granted
        #expect(
            IssueFix(
                issue: .permissionDenied(.screenRecording), enginePreference: .automatic,
                warnings: [.screenRecordingNeedsRelaunch], permissions: screenAllowed, hasAsked: notYet) == .relaunch)
        // The buttons say what they do.
        #expect(IssueFix.allow(.microphone).title == "Allow…")
        #expect(IssueFix.openSystemSettings(.microphone).title == "Open System Settings")
        #expect(IssueFix.allow(.screenRecording).accessibilityLabel == "Allow Screen Recording")
        #expect(IssueFix.openSystemSettings(.screenRecording).accessibilityLabel == "Open System Settings")
    }

    @Test("What was asked for is remembered across launches, one permission at a time")
    func askedPermissionsAreRemembered() {
        let suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("No defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PermissionAsks(defaults: defaults)
        #expect(PermissionKind.allCases.allSatisfy { !first.hasAsked($0) })
        first.markAsked(.screenRecording)
        #expect(first.hasAsked(.screenRecording))
        #expect(!first.hasAsked(.microphone))
        // A new launch reads it back.
        let second = PermissionAsks(defaults: defaults)
        #expect(second.hasAsked(.screenRecording))
        #expect(!second.hasAsked(.microphone))
        #expect(!second.hasAsked(.notifications))
    }

    @Test("Asking goes through the controller and is remembered once the system has answered")
    func askingIsRemembered() async throws {
        let suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let asks = PermissionAsks(defaults: defaults)
        let controller = await SettingsFixtures.controller(
            permissions: PermissionsSnapshot(
                microphone: .notDetermined, screenRecording: .notDetermined, speechRecognition: .granted,
                notifications: .notDetermined))
        #expect(!asks.hasAsked(.microphone))
        let granted = await controller.ask(for: .microphone, asks: asks)
        #expect(granted)
        #expect(asks.hasAsked(.microphone))
        #expect(!asks.hasAsked(.screenRecording), "Only what was asked for")
        #expect(PermissionAsks(defaults: defaults).hasAsked(.microphone), "Written to the defaults")
    }

    @Test("Notifications that are off are mentioned when a rule that is on alerts with one")
    func notificationsOffHint() {
        let off = PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .notDetermined)
        var allowed = off
        allowed.notifications = .granted
        var refused = off
        refused.notifications = .denied
        var configuration = DemoFixtures.configuration  // both rules are on and notify
        #expect(PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: off))
        #expect(PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: refused))
        #expect(!PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: allowed))
        // Rules that are off, or that do not notify, have nothing to say about it.
        configuration.rules[0].isEnabled = false
        #expect(PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: off))
        configuration.rules[1].channels = [.sound]
        #expect(!PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: off))
        configuration.rules = []
        #expect(!PopoverNotices.showsNotificationsOff(configuration: configuration, permissions: off))
        // The popover makes room for it, like for any other note.
        #expect(PopoverNotices.isShown(state: .off, warnings: [], notificationsAreOff: true))
        #expect(!PopoverNotices.isShown(state: .off, warnings: []))
        #expect(NotificationsOffNotice.title(for: .allow) == "Turn On")
        #expect(NotificationsOffNotice.title(for: .openSystemSettings) == "Open System Settings")
    }

    @Test("The local model that cannot keep up is not told to switch to Light when it is Light")
    func fallingBehindAdvice() {
        #expect(WarningNotice.fallingBehindMessage(usingLightModel: false) == "Local model can't keep up. Switch to Light in Settings.")
        #expect(WarningNotice.fallingBehindMessage(usingLightModel: true) == "Local model can't keep up.")
        #expect(WarningNotice.isLight(active: .whisperLight, size: .balanced))
        #expect(!WarningNotice.isLight(active: .whisperBalanced, size: .light))
        #expect(WarningNotice.isLight(active: nil, size: .light))
        #expect(!WarningNotice.isLight(active: nil, size: .balanced))
    }

    @Test("The popover reads the permissions again when it opens, and whenever a window becomes key")
    func popoverRefreshesPermissions() async throws {
        let start = PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .notDetermined)
        let permissions = ChangingPermissions(start)
        var dependencies = RuntimeDependencies.inert()
        dependencies.permissions = permissions
        let controller = ListeningController(dependencies: dependencies)
        // Nothing has read the permissions yet: they are all "not decided".
        #expect(controller.permissions.microphone == .notDetermined)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MenuBarPopover().environment(controller).environment(WindowRouter()))
        defer { window.contentView = nil }

        // Opening reads them.
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.permissions == start)

        // One was turned on in System Settings; the popover is opened again, and its window becomes key.
        var later = start
        later.notifications = .granted
        permissions.set(later)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.permissions == later)
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

/// A `PermissionAsks` on a defaults suite of its own, with `asked` marked, for the length of `body`: nothing of the real
/// settings is read or written.
@MainActor
func withScratchAsks<T>(asked: [PermissionKind] = [], _ body: (PermissionAsks) throws -> T) throws -> T {
    let suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw ScratchError.noSuite }
    defer { defaults.removePersistentDomain(forName: suite) }
    let asks = PermissionAsks(defaults: defaults)
    for kind in asked { asks.markAsked(kind) }
    return try body(asks)
}

enum ScratchError: Error {
    case noSuite
}

/// Permissions that can be changed while a test runs.
final class ChangingPermissions: PermissionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PermissionsSnapshot

    init(_ snapshot: PermissionsSnapshot) {
        current = snapshot
    }

    func set(_ snapshot: PermissionsSnapshot) {
        lock.withLock { current = snapshot }
    }

    func snapshot() async -> PermissionsSnapshot {
        lock.withLock { current }
    }

    func request(_ kind: PermissionKind) async -> Bool { true }
}
