import Foundation
import NameAlertAlerts  // not @testable: these tests see only what the app and the runtime see
import NameAlertCore
import Testing
import os

// MARK: - Helpers

private struct Boom: Error {}

/// A clock the test moves by hand. `now` is what the dispatcher gets as its `now`.
private final class TestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)
    private let elapsed = OSAllocatedUnfairLock(initialState: 0.0)

    var now: Date { Self.start.addingTimeInterval(elapsed.withLock { $0 }) }

    /// The moment `seconds` after the start.
    static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func set(to seconds: Double) { elapsed.withLock { $0 = seconds } }
}

/// A door that holds callers back until the test opens it. The callers do not notice being cancelled.
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let passThrough = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if passThrough { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// What a fake channel does when it is asked to deliver.
private enum Behavior: Sendable {
    case succeed
    case fail(any Error)
    /// Never finishes by itself; ends (by throwing) when cancelled.
    case hang
    /// Never finishes until the gate opens, and does not react to being cancelled, like a system call would not.
    case hangIgnoringCancellation(Gate)
}

/// A channel that records what it was asked to deliver.
private final class FakeChannel: AlertChannel {
    private struct State {
        var behavior: Behavior
        var hits: [Hit] = []
        var settings: [ChannelSettings] = []
        var cancellations = 0
    }

    let kind: ChannelKind
    private let state: OSAllocatedUnfairLock<State>

    init(_ kind: ChannelKind, _ behavior: Behavior = .succeed) {
        self.kind = kind
        state = OSAllocatedUnfairLock(initialState: State(behavior: behavior))
    }

    /// How many times it was asked to deliver, whether or not that worked.
    var attempts: Int { state.withLock { $0.hits.count } }
    var hits: [Hit] { state.withLock { $0.hits } }
    var receivedSettings: [ChannelSettings] { state.withLock { $0.settings } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func setBehavior(_ behavior: Behavior) { state.withLock { $0.behavior = behavior } }

    func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        let behavior = state.withLock { state -> Behavior in
            state.hits.append(hit)
            state.settings.append(settings)
            return state.behavior
        }
        switch behavior {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .hang:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                state.withLock { $0.cancellations += 1 }
                throw error
            }
        case .hangIgnoringCancellation(let gate):
            await gate.wait()
        }
    }
}

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func hit(segmentID: String = "s1") -> Hit {
    Hit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, ruleID: ruleID, ruleName: "My name",
        term: "Bala", matchedText: "Bala", context: "…can Bala share the deck…",
        timestamp: Date(timeIntervalSince1970: 1_760_175_000), source: .systemAudio,
        engine: .appleSpeechTranscriber, segmentID: segmentID)
}

private func rule(_ channels: Set<ChannelKind>) -> Rule {
    Rule(id: ruleID, name: "My name", terms: ["Bala"], channels: channels)
}

/// Settings in which every channel is set up.
private func allConfigured() -> ChannelSettings {
    var settings = ChannelSettings()
    settings.ntfy.topic = "alerts"
    settings.telegramCall.user = "bala"
    settings.webhook.url = "https://hooks.example/alert"
    return settings
}

/// True once `condition` holds. Gives up after `timeout`, so a test that goes wrong fails instead of hanging.
private func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func makeDispatcher(
    _ channels: [FakeChannel], clock: TestClock, settings: ChannelSettings = ChannelSettings(),
    globalCooldown: Double = 3, timeout: Duration = .seconds(10)
) async -> AlertDispatcher {
    let dispatcher = AlertDispatcher(
        channels: channels, secrets: InMemorySecretStore(), deliveryTimeout: timeout, now: { clock.now })
    await dispatcher.configure(settings: settings, globalCooldownSeconds: globalCooldown)
    return dispatcher
}

// MARK: - Tests

@Suite("AlertDispatcher", .timeLimit(.minutes(1)))
struct AlertDispatcherTests {
    // MARK: Routing

    @Test func routesToConfiguredRuleChannels() async {
        let sound = FakeChannel(.sound)
        let ntfy = FakeChannel(.ntfy)
        let notification = FakeChannel(.notification)
        // The default ntfy topic is empty, so ntfy is not set up.
        let dispatcher = await makeDispatcher([sound, ntfy, notification], clock: TestClock())

        let delivered = await dispatcher.dispatch(hit(), rule: rule([.sound, .ntfy]))

        #expect(delivered)
        #expect(sound.attempts == 1)
        #expect(ntfy.attempts == 0)  // in the rule, but not set up
        #expect(notification.attempts == 0)  // set up, but not in the rule
    }

    @Test func deliversTheHitAndTheCurrentSettings() async throws {
        let ntfy = FakeChannel(.ntfy)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([ntfy], clock: clock)
        await dispatcher.configure(settings: allConfigured(), globalCooldownSeconds: 3)

        await dispatcher.dispatch(hit(), rule: rule([.ntfy]))

        #expect(ntfy.hits == [hit()])
        #expect(ntfy.receivedSettings.first?.ntfy.topic == "alerts")
    }

    @Test func reachesEveryConfiguredChannelOfTheRule() async {
        let channels = ChannelKind.allCases.map { FakeChannel($0) }
        let dispatcher = await makeDispatcher(channels, clock: TestClock(), settings: allConfigured())

        await dispatcher.dispatch(hit(), rule: rule(Set(ChannelKind.allCases)))

        #expect(channels.allSatisfy { $0.attempts == 1 })
    }

    @Test func aKindWithoutAChannelIsSkipped() async {
        let sound = FakeChannel(.sound)
        let dispatcher = await makeDispatcher([sound], clock: TestClock(), settings: allConfigured())

        let delivered = await dispatcher.dispatch(hit(), rule: rule([.sound, .webhook]))

        #expect(delivered)
        #expect(sound.attempts == 1)
        #expect(await dispatcher.lastFailures().isEmpty)
    }

    // MARK: Global cooldown

    @Test func globalCooldown() async {
        let sound = FakeChannel(.sound)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound], clock: clock, globalCooldown: 3)
        let rule = rule([.sound])

        clock.set(to: 0)
        #expect(await dispatcher.dispatch(hit(), rule: rule))
        clock.set(to: 1)
        #expect(await dispatcher.dispatch(hit(), rule: rule) == false)
        clock.set(to: 3.1)
        #expect(await dispatcher.dispatch(hit(), rule: rule))

        #expect(sound.attempts == 2)  // the suppressed hit reached no channel
    }

    @Test func aSuppressedHitDoesNotExtendTheCooldown() async {
        let clock = TestClock()
        let dispatcher = await makeDispatcher([FakeChannel(.sound)], clock: clock, globalCooldown: 3)
        let rule = rule([.sound])

        clock.set(to: 0)
        #expect(await dispatcher.dispatch(hit(), rule: rule))
        clock.set(to: 2)
        #expect(await dispatcher.dispatch(hit(), rule: rule) == false)
        clock.set(to: 3)  // 3 s after the hit that was delivered, 1 s after the one that was not
        #expect(await dispatcher.dispatch(hit(), rule: rule))
    }

    @Test func cooldownOfZeroSuppressesNothing() async {
        let sound = FakeChannel(.sound)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound], clock: clock, globalCooldown: 0)

        for _ in 0..<3 { #expect(await dispatcher.dispatch(hit(), rule: rule([.sound]))) }

        #expect(sound.attempts == 3)
    }

    @Test func aClockSteppedBackDoesNotSilenceTheDispatcher() async {
        let clock = TestClock()
        let dispatcher = await makeDispatcher([FakeChannel(.sound)], clock: clock, globalCooldown: 3)

        clock.set(to: 100)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
        clock.set(to: 40)  // the user set the clock back an hour, say
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
    }

    @Test func theCooldownFollowsConfigure() async {
        let clock = TestClock()
        let dispatcher = await makeDispatcher([FakeChannel(.sound)], clock: clock, globalCooldown: 3)

        clock.set(to: 0)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
        await dispatcher.configure(settings: ChannelSettings(), globalCooldownSeconds: 0.5)
        clock.set(to: 1)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
    }

    @Test func aCooldownOutsideTheRangeIsClamped() async {
        let clock = TestClock()
        let dispatcher = await makeDispatcher([FakeChannel(.sound)], clock: clock, globalCooldown: 3)
        await dispatcher.configure(settings: ChannelSettings(), globalCooldownSeconds: 1_000)

        clock.set(to: 0)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
        clock.set(to: 31)  // longer than the longest cooldown a user can pick
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))

        await dispatcher.configure(settings: ChannelSettings(), globalCooldownSeconds: -5)
        clock.set(to: 31.001)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))  // negative counts as none
    }

    // MARK: Slow and failing channels

    @Test func hangingChannelDoesNotBlockOthers() async {
        let sound = FakeChannel(.sound, .hang)
        let notification = FakeChannel(.notification)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound, notification], clock: clock, timeout: .milliseconds(200))

        let started = ContinuousClock.now
        let delivered = await dispatcher.dispatch(hit(), rule: rule([.sound, .notification]))
        let elapsed = ContinuousClock.now - started

        #expect(delivered)
        #expect(elapsed < .seconds(1))
        #expect(elapsed >= .milliseconds(150))  // it waited for the timeout; it did not give up early
        #expect(notification.attempts == 1)
        let failures = await dispatcher.lastFailures()
        #expect(failures[.sound]?.reason == "Timed out")
        #expect(failures[.sound]?.kind == .sound)
        #expect(failures[.sound]?.date == clock.now)
        #expect(failures[.notification] == nil)
        // The timed-out channel was told to stop.
        #expect(await eventually { sound.cancellations == 1 })
    }

    @Test func aChannelThatIgnoresCancellationStillTimesOut() async {
        let gate = Gate()
        let sound = FakeChannel(.sound, .hangIgnoringCancellation(gate))
        let notification = FakeChannel(.notification)
        let dispatcher = await makeDispatcher(
            [sound, notification], clock: TestClock(), timeout: .milliseconds(200))

        let started = ContinuousClock.now
        await dispatcher.dispatch(hit(), rule: rule([.sound, .notification]))
        let elapsed = ContinuousClock.now - started
        gate.open()  // let the stuck delivery go, so that nothing is left waiting after the test

        #expect(elapsed < .seconds(1))
        #expect(notification.attempts == 1)
        #expect(await dispatcher.lastFailures()[.sound]?.reason == "Timed out")
    }

    @Test func failureRecordedAndCleared() async {
        let webhook = FakeChannel(.webhook, .fail(Boom()))
        let clock = TestClock()
        let dispatcher = await makeDispatcher([webhook], clock: clock, settings: allConfigured())

        clock.set(to: 10)
        await dispatcher.dispatch(hit(), rule: rule([.webhook]))

        let failure = await dispatcher.lastFailures()[.webhook]
        #expect(failure == DeliveryFailure(kind: .webhook, reason: String(describing: Boom()), date: TestClock.at(10)))

        webhook.setBehavior(.succeed)
        clock.set(to: 20)
        await dispatcher.dispatch(hit(), rule: rule([.webhook]))

        #expect(await dispatcher.lastFailures()[.webhook] == nil)
        #expect(webhook.attempts == 2)
    }

    @Test func oneFailureLeavesTheOtherChannelsFailuresAlone() async {
        let sound = FakeChannel(.sound, .fail(Boom()))
        let notification = FakeChannel(.notification)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound, notification], clock: clock)

        await dispatcher.dispatch(hit(), rule: rule([.sound, .notification]))
        sound.setBehavior(.succeed)
        clock.set(to: 5)
        // Only the notification is in this rule, so the sound's failure stays until the sound delivers again.
        await dispatcher.dispatch(hit(), rule: rule([.notification]))

        let failures = await dispatcher.lastFailures()
        #expect(failures.keys.sorted { $0.rawValue < $1.rawValue } == [.sound])
    }

    @Test func aNetworkErrorIsReportedWithoutTheAddress() async {
        let url = URL(string: "https://hooks.example/services/T000/B000/secret-token")!
        let error = URLError(
            .notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        let dispatcher = await makeDispatcher(
            [FakeChannel(.webhook, .fail(error))], clock: TestClock(), settings: allConfigured())

        await dispatcher.dispatch(hit(), rule: rule([.webhook]))

        let reason = await dispatcher.lastFailures()[.webhook]?.reason
        #expect(reason == error.localizedDescription)
        #expect(reason?.contains("secret-token") == false)
    }

    @Test func overlappingDispatchesEachFinishTheirOwnDeliveries() async {
        let gate = Gate()
        let slow = FakeChannel(.sound, .hangIgnoringCancellation(gate))
        let fast = FakeChannel(.notification)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([slow, fast], clock: clock, globalCooldown: 0)

        let first = Task { await dispatcher.dispatch(hit(), rule: rule([.sound])) }
        #expect(await eventually { slow.attempts == 1 })
        // The first dispatch is still waiting on the sound; a second one is not held up by it.
        #expect(await dispatcher.dispatch(hit(), rule: rule([.notification])))
        #expect(fast.attempts == 1)

        gate.open()
        #expect(await first.value)
        #expect(await dispatcher.lastFailures().isEmpty)
    }

    // MARK: Cancellation

    @Test func cancellingADispatchStopsItsDeliveriesAndRecordsNoFailure() async {
        let sound = FakeChannel(.sound, .hang)
        let dispatcher = await makeDispatcher([sound], clock: TestClock(), timeout: .seconds(30))

        let task = Task { await dispatcher.dispatch(hit(), rule: rule([.sound])) }
        #expect(await eventually { sound.attempts == 1 })
        task.cancel()

        let started = ContinuousClock.now
        _ = await task.value
        #expect(ContinuousClock.now - started < .seconds(2))  // it did not wait for the 30 s timeout
        #expect(await eventually { sound.cancellations == 1 })
        #expect(await dispatcher.lastFailures().isEmpty)  // a cancelled delivery is not the channel's fault
    }

    // MARK: Test deliveries

    @Test func testBypassesCooldown() async throws {
        let sound = FakeChannel(.sound)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound], clock: clock, globalCooldown: 3)

        clock.set(to: 0)
        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
        clock.set(to: 0.1)
        try await dispatcher.test(.sound, hit: hit(segmentID: "test"))

        #expect(sound.attempts == 2)
        #expect(sound.hits.last?.segmentID == "test")
    }

    @Test func testDoesNotStartTheCooldown() async throws {
        let sound = FakeChannel(.sound)
        let clock = TestClock()
        let dispatcher = await makeDispatcher([sound], clock: clock, globalCooldown: 3)

        clock.set(to: 0)
        try await dispatcher.test(.sound, hit: hit(segmentID: "test"))
        clock.set(to: 0.1)

        #expect(await dispatcher.dispatch(hit(), rule: rule([.sound])))
        #expect(sound.attempts == 2)
    }

    @Test func testIgnoresTheRuleAndUsesTheCurrentSettings() async throws {
        let webhook = FakeChannel(.webhook)
        let dispatcher = await makeDispatcher([webhook], clock: TestClock(), settings: allConfigured())

        try await dispatcher.test(.webhook, hit: hit(segmentID: "test"))

        #expect(webhook.receivedSettings.first?.webhook.url == "https://hooks.example/alert")
    }

    @Test func testRethrowsTheChannelsErrorAndRecordsIt() async {
        let webhook = FakeChannel(.webhook, .fail(Boom()))
        let clock = TestClock()
        let dispatcher = await makeDispatcher([webhook], clock: clock, settings: allConfigured())

        clock.set(to: 7)
        await #expect(throws: Boom.self) {
            try await dispatcher.test(.webhook, hit: hit(segmentID: "test"))
        }
        #expect(
            await dispatcher.lastFailures()[.webhook]
                == DeliveryFailure(kind: .webhook, reason: String(describing: Boom()), date: TestClock.at(7)))

        // A test that works again clears what the failed one left.
        webhook.setBehavior(.succeed)
        try? await dispatcher.test(.webhook, hit: hit(segmentID: "test"))
        #expect(await dispatcher.lastFailures()[.webhook] == nil)
    }

    @Test func testGivesUpAfterTheTimeout() async {
        let dispatcher = await makeDispatcher(
            [FakeChannel(.ntfy, .hang)], clock: TestClock(), settings: allConfigured(), timeout: .milliseconds(200))

        let started = ContinuousClock.now
        await #expect(throws: AlertDeliveryError.timedOut) {
            try await dispatcher.test(.ntfy, hit: hit(segmentID: "test"))
        }

        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await dispatcher.lastFailures()[.ntfy]?.reason == "Timed out")
    }

    @Test func testWithoutAChannelThrows() async {
        let dispatcher = await makeDispatcher([FakeChannel(.sound)], clock: TestClock())

        await #expect(throws: AlertDeliveryError.noChannel(.webhook)) {
            try await dispatcher.test(.webhook, hit: hit(segmentID: "test"))
        }
        #expect(await dispatcher.lastFailures().isEmpty)
    }

    // MARK: Messages

    @Test func deliveryErrorsReadAsPlainSentences() {
        #expect(AlertDeliveryError.timedOut.localizedDescription == "Timed out")
        #expect(String(describing: AlertDeliveryError.timedOut) == "Timed out")
        #expect(AlertDeliveryError.notConfigured(.ntfy).localizedDescription.isEmpty == false)
        #expect(AlertDeliveryError.invalidAddress(.webhook).localizedDescription.isEmpty == false)
        #expect(AlertDeliveryError.noChannel(.sound).localizedDescription.isEmpty == false)
    }
}
