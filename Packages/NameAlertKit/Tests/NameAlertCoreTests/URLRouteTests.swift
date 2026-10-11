import Foundation
import NameAlertCore  // not @testable: these tests see only what other modules see
import Testing

/// Every row of the table in the task: a URL and the route it must give (`nil`: not a route).
private let tableRows: [(String, URLRoute?)] = [
    ("namealert://start", .start),
    ("namealert://pause", .pause),
    ("namealert://toggle", .toggle),
    ("namealert://resume", .resume),
    ("namealert://snooze", .snooze(minutes: 30)),
    ("namealert://snooze?minutes=45", .snooze(minutes: 45)),
    ("namealert://snooze?minutes=0", .snooze(minutes: 1)),
    ("namealert://snooze?minutes=99999", .snooze(minutes: 1440)),
    ("namealert://snooze?minutes=abc", .snooze(minutes: 30)),
    ("namealert://open/settings", .openSettings),
    ("namealert://open/history", .openHistory),
    ("namealert://open/live", .openLive),
    ("NAMEALERT://START", .start),
    ("namealert://delete-all", nil),
    ("namealert://", nil),
    ("https://example.com/start", nil),
]

@Suite("URLRoute")
struct URLRouteTests {
    private func route(_ string: String) throws -> URLRoute? {
        URLRoute(url: try #require(URL(string: string), "not a URL: \(string)"))
    }

    // MARK: The routes

    @Test(arguments: tableRows)
    func routes(urlString: String, expected: URLRoute?) throws {
        #expect(try route(urlString) == expected)
    }

    // MARK: Case and trailing slash

    @Test(arguments: [
        ("NameAlert://Pause", URLRoute.pause),
        ("namealert://PAUSE", .pause),
        ("NAMEALERT://Open/Settings", .openSettings),
        ("namealert://OPEN/HISTORY", .openHistory),
        ("NameAlert://Snooze?minutes=15", .snooze(minutes: 15)),
    ])
    func schemeAndRouteIgnoreCase(urlString: String, expected: URLRoute) throws {
        #expect(try route(urlString) == expected)
    }

    @Test(arguments: [
        ("namealert://start/", URLRoute.start),
        ("namealert://pause///", .pause),
        ("namealert://open/settings/", .openSettings),
        ("namealert://open/live/", .openLive),
        ("namealert://snooze/", .snooze(minutes: 30)),
        ("namealert://snooze/?minutes=10", .snooze(minutes: 10)),
    ])
    func trailingSlashIsIgnored(urlString: String, expected: URLRoute) throws {
        #expect(try route(urlString) == expected)
    }

    // MARK: Snooze minutes

    @Test(arguments: [
        ("namealert://snooze?minutes=1", 1),
        ("namealert://snooze?minutes=2", 2),
        ("namealert://snooze?minutes=1439", 1439),
        ("namealert://snooze?minutes=1440", 1440),
        ("namealert://snooze?minutes=1441", 1440),
        ("namealert://snooze?minutes=-5", 1),  // a whole number, so it is clamped, not ignored
        ("namealert://snooze?minutes=", 30),
        ("namealert://snooze?minutes", 30),
        ("namealert://snooze?minutes=1.5", 30),
        ("namealert://snooze?minutes=45min", 30),
        ("namealert://snooze?minutes=99999999999999999999", 30),  // too large to read at all, so not clamped
        ("namealert://snooze?minute=45", 30),  // the name must be exactly "minutes" ...
        ("namealert://snooze?Minutes=45", 30),  // ... in lower case, unlike the scheme and the route
        ("namealert://snooze?minutes=20&minutes=40", 20),  // the first one counts
        ("namealert://snooze?other=1&minutes=20&more=2", 20),
        ("namealert://snooze?other=1", 30),
    ])
    func snoozeMinutes(urlString: String, expected: Int) throws {
        #expect(try route(urlString) == .snooze(minutes: expected))
    }

    @Test func queryOnlyMattersToSnooze() throws {
        #expect(try route("namealert://start?minutes=5") == .start)
        #expect(try route("namealert://pause?minutes=5&x=y") == .pause)
        #expect(try route("namealert://open/settings?minutes=5") == .openSettings)
    }

    // MARK: Not a route

    @Test(arguments: [
        "namealert://open",
        "namealert://open/",
        "namealert://open/settings/more",
        "namealert://open/unknown",
        "namealert://start/now",
        "namealert://snooze/30",
        "namealert://pause-all",
        "namealert://delete-all/rules",
        "namealert://delete/rules?id=all",
        "namealert://set-channel?topic=x",
        "namealert://?minutes=5",
        "namealert-beta://start",
        "namealerts://start",
        "http://start",
        "https://namealert/start",
        "file:///start",
        "mailto:start@example.com",
        "start",
        "/start",
    ])
    func everythingElseIsNil(urlString: String) throws {
        #expect(try route(urlString) == nil)
    }
}
