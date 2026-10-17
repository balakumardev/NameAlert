import Observation

/// Opens the app's windows on behalf of code that cannot open them itself: the app delegate (setup at launch),
/// `takeheed://open/…` links, notification actions, and the menu bar popover.
///
/// `open(_:)` only records the request. `StatusIcon`, which lives as long as the app does, watches `pending`, brings
/// the app forward, opens the window with SwiftUI's `openWindow` or `openSettings`, and takes the request.
@MainActor
@Observable
final class WindowRouter {
    enum Destination: Hashable, Sendable {
        case settings, onboarding, history, live, crashReport, reportProblem

        /// The id of the `Window` scene that shows it; `nil` for Settings, which `openSettings` opens.
        var windowID: String? {
            switch self {
            case .settings: nil
            case .onboarding: WindowID.onboarding
            case .history: WindowID.history
            case .live: WindowID.live
            case .crashReport: WindowID.crashReport
            case .reportProblem: WindowID.reportProblem
            }
        }
    }

    /// The window to open next, until `StatusIcon` opens it.
    private(set) var pending: Destination?

    /// How many times setup was asked to start over. A `Window` scene keeps its views' state when its window is
    /// closed and opened again, so setup's identity is this number (`OnboardingWindowContent`): each request gets a
    /// setup that starts at Welcome, not the one that was left half way.
    private(set) var onboardingRequests = 0

    /// How many times the crash report window and the problem report window were asked for. Like setup, a window keeps
    /// its views' state when it is closed and opened again, and each of these must start from what is true now (the
    /// crashes that wait, an empty message): the window's content loads again when the number changes.
    private(set) var crashReportRequests = 0
    private(set) var reportProblemRequests = 0

    /// The Settings pane asked for with `openSettings(at:)`, until Settings takes it.
    private(set) var requestedSection: SettingsSection?

    init() {}

    /// Asks for a window. Asking for setup starts it over, unless `startsOver` is false: that brings forward the setup
    /// that is open (or opens it where it was left) without losing what was typed in it.
    func open(_ destination: Destination, startsOver: Bool = true) {
        if destination == .onboarding, startsOver { onboardingRequests += 1 }
        if destination == .crashReport { crashReportRequests += 1 }
        if destination == .reportProblem { reportProblemRequests += 1 }
        pending = destination
    }

    /// Hands over the pending request and forgets it.
    func takePending() -> Destination? {
        defer { pending = nil }
        return pending
    }

    /// Opens Settings on `section`, for code outside Settings: the menu bar popover's "See Pro…".
    func openSettings(at section: SettingsSection) {
        requestedSection = section
        open(.settings)
    }

    /// Hands over the pane asked for and forgets it.
    func takeRequestedSection() -> SettingsSection? {
        defer { requestedSection = nil }
        return requestedSection
    }
}

/// The ids of the app's `Window` scenes.
enum WindowID {
    static let onboarding = "onboarding"
    static let history = "history"
    static let live = "live"
    static let crashReport = "crash-report"
    static let reportProblem = "report-problem"
}
