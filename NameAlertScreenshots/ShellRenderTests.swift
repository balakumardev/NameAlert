import AppKit
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

@Suite("Shell renders", .serialized)
@MainActor
struct ShellRenderTests {
    @Test("Every status icon symbol exists on this system")
    func symbolsExist() {
        for name in StatusIconImage.symbolNames {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing SF Symbol \(name)")
        }
    }

    @Test("The status icon renders for every state", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func statusIcons(appearance: NSAppearance.Name) throws {
        let strip = StatusIconStrip(entries: StatusIconStrip.allStates())
        let name = appearance == .darkAqua ? "status-icons-dark" : "status-icons"
        let url = try RenderHarness.render(strip, name: name, appearance: appearance)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Each state has its own icon and description")
    func iconsDifferByState() {
        let entries = StatusIconStrip.allStates()
        let pictures = entries.map { StatusIconImage.symbolName(for: $0.state, justHeard: $0.justHeard) }
        #expect(pictures == ["ear", "ear", "ear.fill", "ear.badge.waveform", "moon.zzz.fill", "phone", "exclamationmark.triangle"])
        let labels = entries.map { StatusIconImage.accessibilityLabel(for: $0.state, justHeard: $0.justHeard) }
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { $0.hasPrefix(AppInfo.displayName) })
    }
}

@Suite("Shell logic")
@MainActor
struct ShellLogicTests {
    /// A controller on the stand-ins whose saved settings start listening when the app opens, as a Mac that has been set
    /// up and keeps "Start listening when the app opens" on.
    private func controllerThatStartsAtLaunch() async -> ListeningController {
        let dependencies = RuntimeDependencies.inert()
        var configuration = DemoFixtures.configuration
        configuration.listening.startOnLaunch = true
        await dependencies.configStore.save(configuration)
        await dependencies.configStore.flush()
        return ListeningController(dependencies: dependencies)
    }

    @Test("A pause that opens the app is not undone by starting at launch")
    func coldLaunchPause() async {
        let controller = await controllerThatStartsAtLaunch()
        let environment = AppEnvironment(controller: controller, router: WindowRouter())
        // The link is carried out first, as when it is what launches the app; then the launch's own start-up.
        await environment.carryOut(.pause)
        await environment.ensureStartedUp()
        #expect(controller.state == .off)
        #expect(controller.configuration.rules.count == 2, "The settings were loaded before the command ran")
    }

    @Test("Every command that reaches the controller waits for the start-up", arguments: [
        URLRoute.start, .pause, .toggle, .resume, .snooze(minutes: 30),
    ])
    func commandsWaitForTheStartUp(route: URLRoute) async {
        let controller = await controllerThatStartsAtLaunch()
        let environment = AppEnvironment(controller: controller, router: WindowRouter())
        await environment.carryOut(route)
        #expect(controller.configuration.rules.count == 2, "\(route) ran before the settings were loaded")
        await controller.pause()  // stops the snooze timer, if there is one
    }

    @Test("A Snooze button on a notification that opens the app is not undone either")
    func coldLaunchSnooze() async {
        let controller = await controllerThatStartsAtLaunch()
        let environment = AppEnvironment(controller: controller, router: WindowRouter())
        await environment.handleNotificationAction(NotificationActions.snoozeActionID)
        await environment.ensureStartedUp()
        if case .snoozed = controller.state {
        } else {
            Issue.record("Expected a snooze, not \(controller.state)")
        }
        await controller.pause()  // stops the snooze timer
    }

    @Test("Links and notification buttons that open a window do not wait for anything")
    func windowsOpenAtOnce() async {
        let router = WindowRouter()
        let environment = AppEnvironment(controller: await controllerThatStartsAtLaunch(), router: router)
        await environment.carryOut(.openSettings)
        #expect(router.takePending() == .settings)
        await environment.carryOut(.openHistory)
        #expect(router.takePending() == .history)
        await environment.carryOut(.openLive)
        #expect(router.takePending() == .live)
        await environment.handleNotificationAction(NotificationActions.openHistoryActionID)
        #expect(router.takePending() == .history)
        await environment.handleNotificationAction("UNKNOWN")
        #expect(router.takePending() == nil)
    }

    @Test("Opening the app again shows Settings, or setup until it is done, and never starts setup over")
    func reopening() async {
        let finishedRouter = WindowRouter()
        let finished = AppEnvironment(controller: DemoFixtures.controller(.off), router: finishedRouter)
        await finished.reopen()
        #expect(finishedRouter.takePending() == .settings)

        var fresh = AppConfiguration()
        fresh.hasCompletedOnboarding = false
        let unfinishedRouter = WindowRouter()
        let unfinished = AppEnvironment(
            controller: DemoFixtures.controller(.off, configuration: fresh), router: unfinishedRouter)
        await unfinished.reopen()
        #expect(unfinishedRouter.takePending() == .onboarding)
        #expect(unfinishedRouter.onboardingRequests == 0, "Setup that is open keeps what was typed in it")
    }

    @Test("The play button before setup is done brings setup forward without starting it over")
    func playButtonKeepsSetup() {
        let router = WindowRouter()
        PopoverHeader.openSetup(on: router)
        #expect(router.takePending() == .onboarding)
        #expect(router.onboardingRequests == 0, "What was typed in setup stays")
    }

    @Test("Each request for setup makes a new setup; the other windows do not")
    func setupIsNewEachTime() {
        let router = WindowRouter()
        #expect(router.onboardingRequests == 0)
        router.open(.onboarding)
        #expect(router.onboardingRequests == 1)
        #expect(router.takePending() == .onboarding)
        router.open(.history)
        router.open(.settings)
        router.open(.live)
        #expect(router.onboardingRequests == 1)
        router.open(.onboarding)
        #expect(router.onboardingRequests == 2)
        router.open(.onboarding, startsOver: false)
        #expect(router.onboardingRequests == 2)
        #expect(router.takePending() == .onboarding)
        #expect(router.takePending() == nil)
    }
}

/// Every state's menu bar icon side by side on a menu-bar-like strip, each named underneath.
private struct StatusIconStrip: View {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let state: ListeningState
        var justHeard = false
        /// Drawn through the real `StatusIcon` with a demo controller; `nil` draws the picture alone (a hit's
        /// highlight lives in `StatusIcon`'s own state).
        var controller: ListeningController?
    }

    let entries: [Entry]

    static func allStates() -> [Entry] {
        let states: [(String, ListeningState)] = [
            ("Off", .off),
            ("Preparing", .preparing(.starting)),
            ("Listening", .listening(DemoFixtures.listeningInfo)),
        ]
        var entries = states.map { Entry(title: $0.0, state: $0.1, controller: DemoFixtures.controller($0.1)) }
        entries.append(Entry(title: "Heard", state: .listening(DemoFixtures.listeningInfo), justHeard: true))
        let more: [(String, ListeningState)] = [
            ("Snoozed", .snoozed(until: DemoFixtures.today(10, 45))),
            ("Call", .waitingForCall),
            ("Error", .error(.permissionDenied(.screenRecording))),
        ]
        entries += more.map { Entry(title: $0.0, state: $0.1, controller: DemoFixtures.controller($0.1)) }
        return entries
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(entries) { entry in
                VStack(spacing: 8) {
                    icon(for: entry)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text(entry.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 56)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func icon(for entry: Entry) -> some View {
        if let controller = entry.controller {
            StatusIcon()
                .environment(controller)
                .environment(WindowRouter())
        } else {
            StatusIconImage(state: entry.state, justHeard: entry.justHeard)
        }
    }
}
