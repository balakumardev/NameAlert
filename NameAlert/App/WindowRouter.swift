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

    init() {}

    func open(_ destination: Destination) {
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
