import AppIntents

/// The phrases that work in Siri and Spotlight with nothing set up in the Shortcuts app.
struct NameAlertShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseListeningIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Listening",
            systemImageName: "pause.circle")
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: ["Start \(.applicationName)"],
            shortTitle: "Start Listening",
            systemImageName: "ear")
        AppShortcut(
            intent: SnoozeAlertsIntent(),
            phrases: ["Snooze \(.applicationName)"],
            shortTitle: "Snooze Alerts",
            systemImageName: "moon.zzz")
    }
}
