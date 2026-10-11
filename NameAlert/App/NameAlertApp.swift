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
            OnboardingView()
                .appEnvironment(environment)
        }

        Window("History", id: WindowID.history) {
            HistoryWindow()
                .appEnvironment(environment)
        }

        Window("Live Transcript", id: WindowID.live) {
            LiveTranscriptWindow()
                .appEnvironment(environment)
        }
    }
}
