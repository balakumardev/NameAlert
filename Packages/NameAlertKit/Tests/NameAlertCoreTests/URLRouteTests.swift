import Foundation
import NameAlertCore  // not @testable: these tests see only what other modules see
import Testing

/// Every row of the table in the task: a URL and the route it must give (`nil`: not a route).
private let tableRows: [(String, URLRoute?)] = [
    ("takeheed://start", .start),
    ("takeheed://pause", .pause),
    ("takeheed://toggle", .toggle),
    ("takeheed://resume", .resume),
    ("takeheed://snooze", .snooze(minutes: 30)),
    ("takeheed://snooze?minutes=45", .snooze(minutes: 45)),
    ("takeheed://snooze?minutes=0", .snooze(minutes: 1)),
    ("takeheed://snooze?minutes=99999", .snooze(minutes: 1440)),
    ("takeheed://snooze?minutes=abc", .snooze(minutes: 30)),
    ("takeheed://open/settings", .openSettings),
    ("takeheed://open/history", .openHistory),
    ("takeheed://open/live", .openLive),
    ("TAKEHEED://START", .start),
    ("takeheed://delete-all", nil),
    ("takeheed://", nil),
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
        ("Takeheed://Pause", URLRoute.pause),
        ("takeheed://PAUSE", .pause),
        ("TAKEHEED://Open/Settings", .openSettings),
        ("takeheed://OPEN/HISTORY", .openHistory),
        ("Takeheed://Snooze?minutes=15", .snooze(minutes: 15)),
    ])
    func schemeAndRouteIgnoreCase(urlString: String, expected: URLRoute) throws {
        #expect(try route(urlString) == expected)
    }

    @Test(arguments: [
        ("takeheed://start/", URLRoute.start),
        ("takeheed://pause///", .pause),
        ("takeheed://open/settings/", .openSettings),
        ("takeheed://open/live/", .openLive),
        ("takeheed://snooze/", .snooze(minutes: 30)),
        ("takeheed://snooze/?minutes=10", .snooze(minutes: 10)),
    ])
    func trailingSlashIsIgnored(urlString: String, expected: URLRoute) throws {
        #expect(try route(urlString) == expected)
    }

    // MARK: Snooze minutes

    @Test(arguments: [
        ("takeheed://snooze?minutes=1", 1),
        ("takeheed://snooze?minutes=2", 2),
        ("takeheed://snooze?minutes=1439", 1439),
        ("takeheed://snooze?minutes=1440", 1440),
        ("takeheed://snooze?minutes=1441", 1440),
        ("takeheed://snooze?minutes=-5", 1),  // a whole number, so it is clamped, not ignored
        ("takeheed://snooze?minutes=", 30),
        ("takeheed://snooze?minutes", 30),
        ("takeheed://snooze?minutes=1.5", 30),
        ("takeheed://snooze?minutes=45min", 30),
        ("takeheed://snooze?minutes=99999999999999999999", 30),  // too large to read at all, so not clamped
        ("takeheed://snooze?minute=45", 30),  // the name must be exactly "minutes" ...
        ("takeheed://snooze?Minutes=45", 30),  // ... in lower case, unlike the scheme and the route
        ("takeheed://snooze?minutes=20&minutes=40", 20),  // the first one counts
        ("takeheed://snooze?other=1&minutes=20&more=2", 20),
        ("takeheed://snooze?other=1", 30),
    ])
    func snoozeMinutes(urlString: String, expected: Int) throws {
        #expect(try route(urlString) == .snooze(minutes: expected))
    }

    @Test func queryOnlyMattersToSnooze() throws {
        #expect(try route("takeheed://start?minutes=5") == .start)
        #expect(try route("takeheed://pause?minutes=5&x=y") == .pause)
        #expect(try route("takeheed://open/settings?minutes=5") == .openSettings)
    }

    // MARK: Not a route

    @Test(arguments: [
        "takeheed://open",
        "takeheed://open/",
        "takeheed://open/settings/more",
        "takeheed://open/unknown",
        "takeheed://start/now",
        "takeheed://snooze/30",
        "takeheed://pause-all",
        "takeheed://delete-all/rules",
        "takeheed://delete/rules?id=all",
        "takeheed://set-channel?topic=x",
        "takeheed://?minutes=5",
        "takeheed-beta://start",
        "takeheeds://start",
        "namealert://start",  // the scheme before the rename
        "http://start",
        "https://takeheed/start",
        "file:///start",
        "mailto:start@example.com",
        "start",
        "/start",
    ])
    func everythingElseIsNil(urlString: String) throws {
        #expect(try route(urlString) == nil)
    }
}
