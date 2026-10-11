import Foundation
import NameAlertCore

/// Sends a hit to the alert channels of the rule that fired, and keeps track of which channels are failing.
///
/// A hit that comes within `globalCooldownSeconds` of the last one that was sent on is held back: `dispatch` returns
/// `false` and nothing is delivered. (Only a hit that is sent on starts the cooldown; a held-back one does not extend
/// it. A clock that is set back counts as the cooldown being over, so that the dispatcher cannot be silenced by it.)
///
/// Otherwise the hit goes to the channels that are both in the rule and set up, all at once. Every delivery has
/// `deliveryTimeout` to finish, and a delivery that is slow, stuck or failing cannot hold up the others: a stuck one
/// is given up on when its time is over, even if it does not react to being cancelled. A delivery that throws or
/// times out is remembered as that channel's last failure, and the next delivery that works clears it.
/// `dispatch` returns `true` when all the deliveries are over, whether or not they worked.
///
/// If the task that calls `dispatch` is cancelled, the deliveries still running are cancelled with it. A cancelled
/// delivery is not a failure of its channel, so none is recorded for it.
public actor AlertDispatcher {
    private let channels: [ChannelKind: any AlertChannel]
    private let secrets: any SecretStore
    private let deliveryTimeout: Duration
    private let now: @Sendable () -> Date
    private let logger = Log.logger("alerts")

    private static let defaultGlobalCooldown = AppConfiguration().globalCooldownSeconds

    private var settings = ChannelSettings()
    private var globalCooldownSeconds = AlertDispatcher.defaultGlobalCooldown
    private var lastDispatch: Date?
    private var failures: [ChannelKind: DeliveryFailure] = [:]

    /// - Parameter channels: The channels that can be delivered to, one for each kind. If two have the same kind,
    ///   the first is used.
    public init(
        channels: [any AlertChannel], secrets: any SecretStore, deliveryTimeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var byKind: [ChannelKind: any AlertChannel] = [:]
        for channel in channels where byKind[channel.kind] == nil { byKind[channel.kind] = channel }
        self.channels = byKind
        self.secrets = secrets
        self.deliveryTimeout = deliveryTimeout
        self.now = now
    }

    /// Sets what the channels are told on their next delivery, and the global cooldown. A cooldown outside
    /// `AppConfiguration.globalCooldownRange` is brought into it. Deliveries that are already running are not changed.
    public func configure(settings: ChannelSettings, globalCooldownSeconds: Double) {
        self.settings = settings
        let range = AppConfiguration.globalCooldownRange
        self.globalCooldownSeconds =
            globalCooldownSeconds.isNaN
            ? Self.defaultGlobalCooldown
            : min(max(globalCooldownSeconds, range.lowerBound), range.upperBound)
    }

    /// Delivers the hit to the rule's channels, unless the global cooldown holds it back (then this returns `false`).
    @discardableResult
    public func dispatch(_ hit: Hit, rule: Rule) async -> Bool {
        let moment = now()
        if let last = lastDispatch, moment >= last, moment.timeIntervalSince(last) < globalCooldownSeconds {
            logger.info("A hit was held back by the global cooldown")
            return false
        }
        lastDispatch = moment

        // Fixed now, so that a later `configure` does not change a delivery that is on its way.
        let settings = settings
        let secrets = secrets
        let timeout = deliveryTimeout
        // In the order of `ChannelKind`, so that what happens does not depend on how a set happens to be ordered.
        let targets = ChannelKind.allCases
            .filter { rule.channels.contains($0) && settings.isConfigured($0) }
            .compactMap { channels[$0] }

        await withTaskGroup(of: (ChannelKind, Outcome).self) { group in
            for channel in targets {
                group.addTask {
                    (channel.kind, await Self.attempt(channel, hit: hit, settings: settings, secrets: secrets, timeout: timeout))
                }
            }
            for await (kind, outcome) in group {
                record(outcome, for: kind)
            }
        }
        return true
    }

    /// Delivers `hit` to one channel, whatever the rule or the cooldown says, and throws what went wrong: the error
    /// the channel threw, `AlertDeliveryError.timedOut` after the delivery timeout, or `noChannel` when the dispatcher
    /// has no channel of that kind. It does not start the cooldown.
    ///
    /// It counts as that channel's latest delivery: a failure is remembered, and a success clears the last one.
    public func test(_ kind: ChannelKind, hit: Hit) async throws {
        guard let channel = channels[kind] else { throw AlertDeliveryError.noChannel(kind) }
        let outcome = await Self.attempt(
            channel, hit: hit, settings: settings, secrets: secrets, timeout: deliveryTimeout)
        record(outcome, for: kind)
        switch outcome {
        case .delivered: return
        case .failed(let error): throw error
        case .timedOut: throw AlertDeliveryError.timedOut
        case .cancelled: throw CancellationError()
        }
    }

    /// The latest failure of each channel whose last delivery did not work.
    public func lastFailures() -> [ChannelKind: DeliveryFailure] {
        failures
    }

    // MARK: Recording

    private func record(_ outcome: Outcome, for kind: ChannelKind) {
        switch outcome {
        case .delivered:
            failures[kind] = nil
        case .failed(let error):
            recordFailure(kind, reason: Self.reason(for: error))
        case .timedOut:
            recordFailure(kind, reason: "Timed out")
        case .cancelled:
            break
        }
    }

    private func recordFailure(_ kind: ChannelKind, reason: String) {
        failures[kind] = DeliveryFailure(kind: kind, reason: reason, date: now())
        // The reason can name an address or an account, so it stays private; which channel failed does not.
        logger.error("A \(kind.rawValue, privacy: .public) alert failed: \(reason, privacy: .private)")
    }

    /// `String(describing:)` of the error, except for a network error: its description lists the address that was
    /// called (a webhook address can hold a secret) and internals nobody can use, so it is replaced by the plain
    /// sentence the system gives for it.
    private static func reason(for error: any Error) -> String {
        if let error = error as? URLError { return error.localizedDescription }
        return String(describing: error)
    }

    // MARK: One delivery against the clock

    private enum Outcome: Sendable {
        case delivered
        case failed(any Error)
        case timedOut
        /// The task that waits for the delivery was cancelled, or the channel itself ended with a cancellation.
        case cancelled
    }

    /// Runs one delivery and waits for it or for `timeout`, whichever comes first, and cancels the other.
    ///
    /// The delivery and the timer are two tasks that report to one stream; the first report is the result. A delivery
    /// that is stuck for good (one that ignores being cancelled) is simply left behind: a task group would wait for
    /// it, and so would this function, long after the timeout.
    private static func attempt(
        _ channel: any AlertChannel, hit: Hit, settings: ChannelSettings, secrets: any SecretStore,
        timeout: Duration
    ) async -> Outcome {
        let (reports, report) = AsyncStream.makeStream(of: Outcome.self)
        let delivery = Task {
            do {
                try await channel.deliver(hit, settings: settings, secrets: secrets)
                report.yield(.delivered)
            } catch is CancellationError {
                report.yield(.cancelled)
            } catch {
                report.yield(.failed(error))
            }
        }
        let timer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }  // cancelled: the delivery was first
            report.yield(.timedOut)
        }
        defer {
            delivery.cancel()
            timer.cancel()
        }
        for await outcome in reports { return outcome }
        return .cancelled  // the stream ends early only when this task is cancelled
    }
}
