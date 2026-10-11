import Observation

/// Opens the app's windows on behalf of code that cannot open them itself: the app delegate (setup at launch),
/// `namealert://open/…` links, notification actions, and the menu bar popover.
///
/// `open(_:)` only records the request. `StatusIcon`, which lives as long as the app does, watches `pending`, brings
/// the app forward, opens the window with SwiftUI's `openWindow` or `openSettings`, and takes the request.
@MainActor
@Observable
final class WindowRouter {
    enum Destination: Hashable, Sendable {
        case settings, onboarding, history, live

        /// The id of the `Window` scene that shows it; `nil` for Settings, which `openSettings` opens.
        var windowID: String? {
            switch self {
            case .settings: nil
            case .onboarding: WindowID.onboarding
            case .history: WindowID.history
            case .live: WindowID.live
            }
        }
    }

    /// The window to open next, until `StatusIcon` opens it.
    private(set) var pending: Destination?

    /// How many times setup was asked to start over. A `Window` scene keeps its views' state when its window is
    /// closed and opened again, so setup's identity is this number (`OnboardingWindowContent`): each request gets a
    /// setup that starts at Welcome, not the one that was left half way.
    private(set) var onboardingRequests = 0

    init() {}

    /// Asks for a window. Asking for setup starts it over, unless `startsOver` is false: that brings forward the setup
    /// that is open (or opens it where it was left) without losing what was typed in it.
    func open(_ destination: Destination, startsOver: Bool = true) {
        if destination == .onboarding, startsOver { onboardingRequests += 1 }
        pending = destination
    }

    /// Hands over the pending request and forgets it.
    func takePending() -> Destination? {
        defer { pending = nil }
        return pending
    }
}

/// The ids of the app's `Window` scenes.
enum WindowID {
    static let onboarding = "onboarding"
    static let history = "history"
    static let live = "live"
}
