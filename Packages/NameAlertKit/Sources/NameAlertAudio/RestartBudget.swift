/// Caps how often a capture run restarts itself: at most `limit` restarts in any rolling `window` (3 in 10 s by
/// default).
///
/// Without a cap, a device that keeps changing (a Bluetooth headset flapping between profiles) would restart the
/// engine forever, and the stream would neither deliver audio nor finish, so the caller's backoff would never see a
/// failure. With it, the run ends instead and the caller decides what happens next.
///
/// A plain value with no clock of its own: the caller passes the time, which keeps it testable.
struct RestartBudget: Sendable, Equatable {
    let limit: Int
    let window: Duration
    /// When the restarts that still count happened, oldest first.
    private var restarts: [ContinuousClock.Instant] = []

    init(limit: Int = 3, window: Duration = .seconds(10)) {
        self.limit = limit
        self.window = window
    }

    /// Whether a restart at `now` fits the budget. An allowed restart counts against the budget for `window`; a
    /// refused one does not count at all.
    mutating func allow(at now: ContinuousClock.Instant) -> Bool {
        restarts.removeAll { now - $0 >= window }
        guard restarts.count < limit else { return false }
        restarts.append(now)
        return true
    }
}
