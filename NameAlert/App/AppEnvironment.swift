import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import UserNotifications

/// The composition root: the one listening controller, window router and secrets model every scene shares, and the
/// app-level commands (launch, `takeheed://` links, notification actions, opening the app again).
@MainActor
final class AppEnvironment {
    static let shared: AppEnvironment = {
        let controller = ListeningController(dependencies: .live(appVersion: AppInfo.version, build: AppInfo.build))
        // The alarm panel's Snooze button and the local model's falling-behind warning reach the controller here.
        ControllerBox.shared.controller = controller
        return AppEnvironment(controller: controller, router: WindowRouter())
    }()

    let controller: ListeningController
    let router: WindowRouter
    /// The Keychain secrets the Alerts settings edit. It reads nothing until a pane asks.
    let secrets = SecretsModel()

    private let logger = Log.logger("app")
    /// The start-up, made once: see `ensureStartedUp()`.
    private var startUp: Task<Void, Never>?

    /// Whether this process is the real app. Under XCTest and in the screenshot host nothing may load the user's
    /// settings, open setup or start listening.
    static let isLive: Bool = {
        #if SCREENSHOT_HOST
        false
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }()

    /// The app uses `shared`; tests make their own, on a controller with stand-ins.
    init(controller: ListeningController, router: WindowRouter) {
        self.controller = controller
        self.router = router
    }

    /// Loads the settings, starts listening if setup is done and the user wants it at launch, and opens setup until
    /// it is done.
    func launch() {
        guard Self.isLive else {
            logger.info("Running under tests: not loading settings or listening")
            return
        }
        let copies = OtherCopies.shared
        copies.refresh()
        if let other = copies.urls.first {
            logger.notice("""
                Other copies macOS may open instead of this one: \(copies.urls.count, privacy: .public), \
                the first at \(other.path, privacy: .private)
                """)
        }
        Task {
            let start = ContinuousClock.now
            await ensureStartedUp()
            let isDone = controller.configuration.hasCompletedOnboarding
            logger.info("""
                Started up in \(start.duration(to: .now), privacy: .public); \
                setup is \(isDone ? "done" : "not done", privacy: .public)
                """)
            if !isDone {
                router.open(.onboarding)
            }
        }
    }

    /// Brings the controller up, once: waits for the copy this one replaced to quit (after a relaunch), then
    /// `bootstrap()` loads the settings and, if setup is done and the user wants it, starts listening.
    ///
    /// Every command that reaches the controller waits for this first. A link or a notification button can be what
    /// opens the app, and it must be carried out after the start-up, not before it: otherwise "start listening when
    /// the app opens" would run second and undo a `takeheed://pause` that launched the app.
    func ensureStartedUp() async {
        if startUp == nil {
            startUp = Task {
                await AppRelaunch.waitForPreviousCopyToQuit()
                await controller.bootstrap()
            }
        }
        await startUp?.value
    }

    /// Carries out a `takeheed://` link. None of them deletes or changes what the user has set up.
    func perform(_ route: URLRoute) {
        Task { await carryOut(route) }
    }

    func carryOut(_ route: URLRoute) async {
        switch route {
        case .openSettings: router.open(.settings)
        case .openHistory: router.open(.history)
        case .openLive: router.open(.live)
        case .start:
            await ensureStartedUp()
            await controller.start()
        case .pause:
            await ensureStartedUp()
            await controller.pause()
        case .toggle:
            await ensureStartedUp()
            await controller.toggle()
        case .resume:
            await ensureStartedUp()
            await controller.resume()
        case .snooze(let minutes):
            await ensureStartedUp()
            await controller.snooze(minutes: minutes)
        }
    }

    /// Answers a click on a hit's notification: its Snooze 15 min button, its Open History button, or the
    /// notification itself (which also opens History).
    func handleNotificationAction(_ actionIdentifier: String) async {
        switch actionIdentifier {
        case NotificationActions.snoozeActionID:
            await ensureStartedUp()
            await controller.snooze(minutes: 15)
        case NotificationActions.openHistoryActionID, UNNotificationDefaultActionIdentifier:
            router.open(.history)
        default:
            break
        }
    }

    /// The app was opened again while it was running (Finder, Launchpad, Spotlight): a menu bar app has no Dock icon
    /// to click, so this is how people look for it. It shows Settings, or setup until setup is done. Setup that is
    /// open already is brought forward, not started over.
    func reopen() async {
        await ensureStartedUp()
        if controller.configuration.hasCompletedOnboarding {
            router.open(.settings)
        } else {
            router.open(.onboarding, startsOver: false)
        }
    }
}

extension View {
    /// Gives a scene's root view the shared controller, window router and secrets model.
    func appEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.controller)
            .environment(environment.router)
            .environment(environment.secrets)
    }
}
