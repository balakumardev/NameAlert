import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import UserNotifications

/// The composition root: the one listening controller, window router and secrets model every scene shares, and the
/// app-level commands (launch, `namealert://` links, notification actions).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let controller: ListeningController
    let router: WindowRouter
    /// The Keychain secrets the Alerts settings edit. It reads nothing until a pane asks.
    let secrets = SecretsModel()

    private let logger = Log.logger("app")

    /// Whether this process is the real app. Under XCTest and in the screenshot host nothing may load the user's
    /// settings, open setup or start listening.
    static let isLive: Bool = {
        #if SCREENSHOT_HOST
        false
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }()

    private init() {
        controller = ListeningController(dependencies: .live(appVersion: AppInfo.version, build: AppInfo.build))
        // The alarm panel's Snooze button and the local model's falling-behind warning reach the controller here.
        ControllerBox.shared.controller = controller
        router = WindowRouter()
    }

    /// Loads the settings, starts listening if setup is done and the user wants it at launch, and opens setup until
    /// it is done.
    func launch() {
        guard Self.isLive else {
            logger.info("Running under tests: not loading settings or listening")
            return
        }
        Task {
            await AppRelaunch.waitForPreviousCopyToQuit()
            await controller.bootstrap()
            if !controller.configuration.hasCompletedOnboarding {
                router.open(.onboarding)
            }
        }
    }

    /// Carries out a `namealert://` link. None of them deletes or changes what the user has set up.
    func perform(_ route: URLRoute) {
        switch route {
        case .start: Task { await controller.start() }
        case .pause: Task { await controller.pause() }
        case .toggle: Task { await controller.toggle() }
        case .resume: Task { await controller.resume() }
        case .snooze(let minutes): Task { await controller.snooze(minutes: minutes) }
        case .openSettings: router.open(.settings)
        case .openHistory: router.open(.history)
        case .openLive: router.open(.live)
        }
    }

    /// Answers a click on a hit's notification: its Snooze 15 min button, its Open History button, or the
    /// notification itself (which also opens History).
    func handleNotificationAction(_ actionIdentifier: String) {
        switch actionIdentifier {
        case NotificationActions.snoozeActionID:
            Task { await controller.snooze(minutes: 15) }
        case NotificationActions.openHistoryActionID, UNNotificationDefaultActionIdentifier:
            router.open(.history)
        default:
            break
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
