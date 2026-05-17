import XCTest
@testable import NameAlert

final class AlertCoordinatorTests: XCTestCase {
    func testParallelDispatchToAllAlerts() async {
        let a = MockAlert(id: "a")
        let b = MockAlert(id: "b")
        let c = MockAlert(id: "c")
        let coord = AlertCoordinator(alerts: [a, b, c], globalCooldown: 0)
        let hit = Hit(keyword: "bala", matchedText: "bala", timestamp: Date(), distance: 0)
        let dispatched = await coord.handle(hit)
        XCTAssertTrue(dispatched)
        let aCount = await a.fireCount.value
        let bCount = await b.fireCount.value
        let cCount = await c.fireCount.value
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)
        XCTAssertEqual(cCount, 1)
    }

    func testGlobalCooldownSuppresses() async {
        let a = MockAlert(id: "a")
        let coord = AlertCoordinator(alerts: [a], globalCooldown: 10)
        let now = Date()
        let h = Hit(keyword: "x", matchedText: "x", timestamp: now, distance: 0)
        _ = await coord.handle(h, now: now)
        let suppressed = await coord.handle(h, now: now.addingTimeInterval(1))
        XCTAssertFalse(suppressed)
        let count = await a.fireCount.value
        XCTAssertEqual(count, 1)
    }

    func testGlobalCooldownReleases() async {
        let a = MockAlert(id: "a")
        let coord = AlertCoordinator(alerts: [a], globalCooldown: 5)
        let now = Date()
        let h = Hit(keyword: "x", matchedText: "x", timestamp: now, distance: 0)
        _ = await coord.handle(h, now: now)
        let after = await coord.handle(h, now: now.addingTimeInterval(6))
        XCTAssertTrue(after)
        let count = await a.fireCount.value
        XCTAssertEqual(count, 2)
    }

    func testNoAlertsNoDispatch() async {
        let coord = AlertCoordinator(alerts: [], globalCooldown: 0)
        let h = Hit(keyword: "x", matchedText: "x", timestamp: Date(), distance: 0)
        let dispatched = await coord.handle(h)
        XCTAssertFalse(dispatched)
    }
}

/// Minimal Sendable mock with an actor-protected counter.
private struct MockAlert: Alert {
    let id: String
    let displayName = "Mock"
    let fireCount = Counter()
    func fire(reason: Hit) async { await fireCount.bump() }
}

private actor Counter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}
