import AppKit
import NameAlertCore

/// Starts a fresh copy of the app and quits this one: ScreenCaptureKit only sees a newly granted Screen Recording
/// permission in a new process.
@MainActor
enum AppRelaunch {
    /// Passed to the new copy, which then waits for this one to quit before it starts listening.
    static let argument = "--relaunched"

    /// How long the new copy waits for the old one to quit.
    private static let waitLimit: Duration = .seconds(6)

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [argument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Log.logger("app").error("Could not relaunch: \(error.localizedDescription, privacy: .public)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// In a copy started by `relaunch()`, waits until the copy that started it has quit, so the two never listen at
    /// the same time. Returns at once in a normal launch.
    static func waitForPreviousCopyToQuit() async {
        guard CommandLine.arguments.contains(argument), let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let deadline = ContinuousClock.now + waitLimit
        while ContinuousClock.now < deadline {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
            if others.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
