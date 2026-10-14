import Foundation

/// A command that arrived through the `takeheed://` URL scheme.
///
/// The routes are `start`, `pause`, `toggle`, `resume`, `snooze?minutes=N`, `open/settings`, `open/history` and
/// `open/live`, for example `takeheed://snooze?minutes=45`. None of them can delete or change anything the user
/// has set up, and anything else is not a route.
public enum URLRoute: Equatable, Sendable {
    case start, pause, toggle, resume, snooze(minutes: Int), openSettings, openHistory, openLive

    /// Reads `url` as a route, or gives `nil` when it is not one.
    ///
    /// The scheme must be `takeheed`. The route is the host followed by the path, for example `open/settings`.
    /// Scheme and route ignore upper and lower case, and a slash at the end is ignored (`takeheed://pause/` works).
    ///
    /// `snooze` reads the query item `minutes`, spelled exactly like that (the first one, if there are several). A
    /// whole number is clamped into 1...1440. Anything else gives 30: a missing or empty value, text that is not a
    /// whole number, or a number too large to read. No other route looks at the query.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "takeheed",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var route = ((components.host ?? "") + components.path).lowercased()
        while route.hasSuffix("/") { route.removeLast() }

        switch route {
        case "start": self = .start
        case "pause": self = .pause
        case "toggle": self = .toggle
        case "resume": self = .resume
        case "snooze": self = .snooze(minutes: Self.snoozeMinutes(in: components.queryItems))
        case "open/settings": self = .openSettings
        case "open/history": self = .openHistory
        case "open/live": self = .openLive
        default: return nil
        }
    }

    private static let defaultSnoozeMinutes = 30
    private static let shortestSnoozeMinutes = 1
    private static let longestSnoozeMinutes = 1440

    /// The `minutes` item as a snooze length, clamped; the default when there is no usable one.
    private static func snoozeMinutes(in queryItems: [URLQueryItem]?) -> Int {
        let requested = queryItems?.first { $0.name == "minutes" }?.value.flatMap { Int($0) }
        return min(max(requested ?? defaultSnoozeMinutes, shortestSnoozeMinutes), longestSnoozeMinutes)
    }
}
