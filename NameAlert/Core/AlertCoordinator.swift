import Foundation

/// Receives `Hit`s from the matcher and dispatches them to all configured `Alert`s
/// in parallel via a TaskGroup. Enforces a global per-coordinator cooldown that
/// applies on top of the matcher's per-keyword cooldown.
actor AlertCoordinator {
    private var alerts: [Alert]
    private var globalCooldown: TimeInterval
    private var lastFiredAt: Date?

    init(alerts: [Alert] = [], globalCooldown: TimeInterval = 0) {
        self.alerts = alerts
        self.globalCooldown = max(0, globalCooldown)
    }

    func setAlerts(_ alerts: [Alert]) { self.alerts = alerts }

    func setGlobalCooldown(_ seconds: TimeInterval) {
        self.globalCooldown = max(0, seconds)
    }

    /// Dispatch a hit to all enabled alerts. Returns true if dispatched, false if
    /// suppressed by global cooldown or no alerts are configured.
    @discardableResult
    func handle(_ hit: Hit, now: Date = Date()) async -> Bool {
        guard !alerts.isEmpty else { return false }
        if let last = lastFiredAt, now.timeIntervalSince(last) < globalCooldown {
            return false
        }
        lastFiredAt = now
        let snapshot = alerts
        await withTaskGroup(of: Void.self) { group in
            for alert in snapshot {
                group.addTask { await alert.fire(reason: hit) }
            }
        }
        return true
    }

    /// Fire a single alert immediately, bypassing cooldown. Used by Settings "Test".
    func test(_ alert: Alert, with hit: Hit) async {
        await alert.fire(reason: hit)
    }
}
