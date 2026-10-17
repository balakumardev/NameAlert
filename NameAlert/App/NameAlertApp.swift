import SwiftUI

/// The menu bar app: the status icon and its popover, Settings, setup, History and the live transcript.
@main
struct NameAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var environment: AppEnvironment { .shared }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover()
                .appEnvironment(environment)
        } label: {
            StatusIcon()
                .appEnvironment(environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .appEnvironment(environment)
        }

        Window("Welcome to \(AppInfo.displayName)", id: WindowID.onboarding) {
            OnboardingWindowContent()
                .appEnvironment(environment)
        }
        .windowResizability(.contentSize)  // 600 × 460 and fixed: setup is not a place to resize

        Window("History", id: WindowID.history) {
            HistoryWindow()
                .appEnvironment(environment)
        }
        .defaultSize(width: 760, height: 520)

        Window("Live Transcript", id: WindowID.live) {
            LiveTranscriptWindow()
                .appEnvironment(environment)
        }
        .defaultSize(width: 620, height: 460)

        Window(CrashReportCopy.windowTitle, id: WindowID.crashReport) {
            CrashReportWindowContent()
                .appEnvironment(environment)
        }
        .windowResizability(.contentSize)

        Window(ReportProblemCopy.windowTitle, id: WindowID.reportProblem) {
            ReportProblemWindowContent()
                .appEnvironment(environment)
        }
        .windowResizability(.contentSize)
    }
}
