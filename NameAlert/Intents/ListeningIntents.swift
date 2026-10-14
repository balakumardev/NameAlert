import AppIntents
import NameAlertRuntime

/// What every intent starts from: the app's one listening controller, with the user's settings loaded.
///
/// Shortcuts can start the app just to run an intent, so one may arrive before the app has finished launching. The
/// controller's `bootstrap()` does nothing when it has run already, so waiting for it here keeps the order the same
/// either way: the settings first, then the intent's command.
@MainActor
enum IntentEnvironment {
    static func controller() async -> ListeningController {
        let controller = AppEnvironment.shared.controller
        await controller.bootstrap()
        return controller
    }

    /// The line the menu bar popover shows for the state: "Listening · System audio", "Paused", "Snoozed until 10:45".
    static func status(of controller: ListeningController) -> String {
        StatusText.title(for: controller.state)
    }

    /// What Siri says and Spotlight shows after an intent.
    static func dialog(_ text: String) -> IntentDialog {
        "\(text)"
    }
}

struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Listening"
    static let description = IntentDescription("Start listening for your words.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        await controller.start()
        let status = IntentEnvironment.status(of: controller)
        return .result(value: status, dialog: IntentEnvironment.dialog(status))
    }
}

struct PauseListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Listening"
    static let description = IntentDescription("Stop listening until you start again.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        await controller.pause()
        let status = IntentEnvironment.status(of: controller)
        return .result(value: status, dialog: IntentEnvironment.dialog(status))
    }
}

struct ToggleListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Listening"
    static let description = IntentDescription("Start if paused, pause if listening.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        await controller.toggle()
        let status = IntentEnvironment.status(of: controller)
        return .result(value: status, dialog: IntentEnvironment.dialog(status))
    }
}

struct SnoozeAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Alerts"
    static let description = IntentDescription("Pause for a while, then listen again.")
    static let openAppWhenRun = false

    /// The same range as the `takeheed://snooze` link.
    private static let minutesRange = 1...1440

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze alerts for \(\.$minutes) minutes")
    }

    @Parameter(title: "Minutes", description: "From 1 to 1440, which is a day.", default: 30, inclusiveRange: (1, 1440))
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        // The range is checked where the number is typed in. One that comes from a variable may be outside it.
        let range = Self.minutesRange
        await controller.snooze(minutes: min(max(minutes, range.lowerBound), range.upperBound))
        let status = IntentEnvironment.status(of: controller)
        return .result(value: status, dialog: IntentEnvironment.dialog(status))
    }
}

struct GetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Status"
    static let description = IntentDescription("Say whether it is listening, paused or snoozed.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = await IntentEnvironment.controller()
        let status = IntentEnvironment.status(of: controller)
        return .result(value: status, dialog: IntentEnvironment.dialog(status))
    }
}
