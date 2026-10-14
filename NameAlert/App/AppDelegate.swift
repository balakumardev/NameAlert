import AppKit
import NameAlertAlerts
import NameAlertCore
import UserNotifications

/// Launch, `namealert://` links, sleep and wake, quitting, and the hit notifications' buttons.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// How long quitting waits for listening to stop and the settings and history to be written.
    private static let quitTimeLimit: Duration = .seconds(4)

    private var environment: AppEnvironment { .shared }
    private let logger = Log.logger("app")
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var isQuitting = false
    private var hasAnsweredQuit = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppEnvironment.isLive else { return }
        NotificationActions.register()
        UNUserNotificationCenter.current().delegate = self
        observeSleepAndWake()
        environment.launch()
    }

    /// Permission problems are not retried on their own; they are checked again whenever the app comes forward, and so
    /// are the other copies of the app (one may have been deleted).
    func applicationDidBecomeActive(_ notification: Notification) {
        guard AppEnvironment.isLive else { return }
        let controller = environment.controller
        Task { await controller.refreshPermissions() }
        OtherCopies.shared.refresh()
    }

    /// The app was opened again while it runs. It has no Dock icon to click, so this is how someone who opened it from
    /// Finder or Spotlight looks for it: Settings, or setup if it is not done. The app handles it, not AppKit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard AppEnvironment.isLive else { return true }
        let environment = environment
        Task { await environment.reopen() }
        return false
    }

    // MARK: - Links

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = URLRoute(url: url) else {
                logger.info("Ignored a link that is not a NameAlert command: \(url.absoluteString, privacy: .private)")
                continue
            }
            environment.perform(route)
        }
    }

    // MARK: - Sleep, wake and quit

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        let controller = environment.controller
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await controller.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await controller.systemDidWake() }
            },
        ]
    }

    /// Writes the settings and history that are waiting, then stops listening, and quits. The writing comes first
    /// (`systemWillSleep()` does it before it stops anything), so that a capture source or an engine that hangs while
    /// it stops cannot keep the files from the disk; it gives up waiting after `quitTimeLimit` so that such a device
    /// cannot hold the app open either.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppEnvironment.isLive else { return .terminateNow }
        // Asked again (say, by logout) while the first request is still being answered: that answer quits the app.
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        let controller = environment.controller
        Task {
            await controller.systemWillSleep()
            answerQuit()
        }
        Task {
            try? await Task.sleep(for: Self.quitTimeLimit)
            answerQuit()
        }
        return .terminateLater
    }

    private func answerQuit() {
        guard !hasAnsweredQuit else { return }
        hasAnsweredQuit = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let environment = await AppEnvironment.shared
        await environment.handleNotificationAction(action)
    }
}
