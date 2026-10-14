import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
@testable import NameAlertRuntime
import NameAlertSpeech
import Testing

// MARK: - Harness

private let bala = Rule(
    id: UUID(uuidString: "B0000000-0000-0000-0000-00000000BA1A")!, name: "My name", terms: ["Bala"], channels: [.sound])

private let systemAudioInfo = ListeningInfo(engine: .appleSpeechTranscriber, source: .systemAudio, localeIdentifier: "en-US")

private func final(_ segmentID: String, _ text: String) -> TranscriptUpdate {
    TranscriptUpdate(segmentID: segmentID, text: text, isFinal: true)
}

private func partial(_ segmentID: String, _ text: String) -> TranscriptUpdate {
    TranscriptUpdate(segmentID: segmentID, text: text, isFinal: false)
}

/// The engine hears "hey Bala" on the first chunk.
private func heyBala() -> FakeSpeech {
    FakeSpeech([.init([final("s1", "hey Bala")])])
}

extension AppConfiguration {
    fileprivate static func test(
        onboarded: Bool = true, startOnLaunch: Bool = false, source: AudioSourceKind = .systemAudio,
        mode: ListeningMode = .always, history: Bool = true, rules: [Rule] = [bala]
    ) -> AppConfiguration {
        var configuration = AppConfiguration()
        configuration.hasCompletedOnboarding = onboarded
        configuration.listening.startOnLaunch = startOnLaunch
        configuration.listening.source = source
        configuration.listening.mode = mode
        configuration.history.isEnabled = history
        configuration.rules = rules
        return configuration
    }
}

extension ListeningState {
    fileprivate var isListening: Bool {
        if case .listening = self { true } else { false }
    }

    fileprivate var isDownloadingModel: Bool {
        if case .preparing(.downloadingModel) = self { true } else { false }
    }
}

/// A controller on fakes, with its configuration in a folder of its own.
@MainActor
private final class Harness {
    let clock = TestClock()
    let sleeper: TestSleeper
    let permissions: FakePermissions
    let capture: FakeCapture
    let speech: FakeSpeech
    let models: FakeModels
    let calls = FakeCallStates()
    let channel: FakeChannel
    let directory: URL
    let controller: ListeningController

    init(
        configuration: AppConfiguration = .test(), capabilities: EngineCapabilities = .analyzer,
        sleeper: TestSleeper = TestSleeper(), permissions: PermissionsSnapshot = .allGranted,
        capture: FakeCapture = FakeCapture(), speech: FakeSpeech = FakeSpeech(), models: FakeModels = FakeModels(),
        channel: FakeChannel = FakeChannel(.sound), otherChannels: [FakeChannel] = [], callDetectionSupported: Bool = true,
        captureCallLimit: Duration? = nil, proAccess: ProAccess = .pro
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("config.json"))

        self.sleeper = sleeper
        self.permissions = FakePermissions(permissions)
        self.capture = capture
        self.speech = speech
        self.models = models
        self.channel = channel
        let clock = clock
        let calls = calls
        let dependencies = RuntimeDependencies(
            configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json"), debounce: .seconds(60)),
            historyStore: HistoryStore(fileURL: directory.appendingPathComponent("history.json"), debounce: .seconds(60)),
            secrets: InMemorySecretStore(),
            permissions: self.permissions,
            capabilities: { capabilities },
            makeSource: { capture.make($0) },
            makeEngine: { speech.make($0) },
            models: models,
            callStates: { calls.subscribe() },
            callDetectionSupported: callDetectionSupported,
            channels: [channel] + otherChannels,
            systemLocaleIdentifier: { "en-US" },
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            backoffBase: .milliseconds(1))
        controller = ListeningController(dependencies: dependencies, proAccess: proAccess)
        if let captureCallLimit { controller.captureCallLimit = captureCallLimit }
    }

    /// Bootstraps, starts, and waits until the controller listens.
    func startListening() async -> Bool {
        await controller.bootstrap()
        await controller.start()
        return await eventually { self.controller.state.isListening }
    }

    /// Stops whatever is still running and removes the folder.
    func finish() async {
        await controller.pause()
        try? FileManager.default.removeItem(at: directory)
    }

    /// How many hits `history.json` holds on disk (0 when there is no file).
    func hitsOnDisk() throws -> Int {
        let url = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try (JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])?.count ?? -1
    }

    func configurationOnDisk() throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    }
}

/// Waits until `condition` holds, looking every millisecond, for at most `timeout`. Returns whether it held.
@MainActor
private func eventually(within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// Lets whatever is due run for a moment: for checking that something does not happen.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(100))
}

// MARK: - The state machine

@MainActor
@Suite("ListeningController", .timeLimit(.minutes(1)))
struct ListeningControllerTests {
    // MARK: Starting

    @Test func bootstrapWithoutOnboardingStaysOff() async throws {
        let h = try Harness(configuration: .test(onboarded: false, startOnLaunch: true))
        await h.controller.bootstrap()
        await settle()
        #expect(h.controller.state == .off)
        #expect(h.capture.madeKinds.isEmpty)
        #expect(h.capture.startCount == 0)
        await h.finish()
    }

    @Test func bootstrapStartsWhenOnboardedAndStartOnLaunch() async throws {
        let h = try Harness(configuration: .test(startOnLaunch: true))
        await h.controller.bootstrap()
        #expect(await eventually { h.controller.state == .listening(systemAudioInfo) })
        #expect(h.controller.configuration.rules == [bala])
        #expect(h.controller.permissions == .allGranted)
        #expect(h.controller.installedModels == Set(WhisperModel.allCases))
        await h.finish()
    }

    @Test func startListensAndFires() async throws {
        let h = try Harness(speech: heyBala())
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .listening(systemAudioInfo) })
        #expect(await eventually { h.channel.hits.count == 1 })
        #expect(await eventually { await h.controller.history().count == 1 })
        #expect(h.controller.recentHits.first?.term == "Bala")
        #expect(h.controller.lastHitAt == h.clock.now)
        #expect(h.controller.activeEngine == .appleSpeechTranscriber)
        #expect(h.controller.liveTranscript == "hey Bala")
        #expect(abs(h.controller.level - 2.0 / 3) < 0.001)  // an rms of 0.1 is −20 dBFS
        #expect(h.speech.preparedLocales == ["en-US"])
        #expect(h.speech.preparedHints == [["Bala"]])
        await h.finish()
    }

    @Test func completeOnboardingSavesAndStarts() async throws {
        // The harness's configuration has "start at launch" off, as "Set up later" leaves it.
        let h = try Harness(configuration: .test(onboarded: false, startOnLaunch: false))
        await h.controller.bootstrap()
        await h.controller.completeOnboarding()
        #expect(h.controller.configuration.hasCompletedOnboarding)
        #expect(h.controller.configuration.listening.startOnLaunch, "Finishing setup turns start at launch back on")
        #expect(await eventually { h.controller.state.isListening })
        await h.controller.systemWillSleep()  // writes the configuration now
        let onDisk = try h.configurationOnDisk()
        #expect(onDisk.hasCompletedOnboarding)
        #expect(onDisk.listening.startOnLaunch)
        await h.finish()
    }

    // MARK: Pausing, toggling, snoozing

    @Test func pauseStopsEverything() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.pause()
        #expect(h.controller.state == .off)
        #expect(h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 0)
        #expect(h.speech.stopCount == 1)
        #expect(await eventually { h.speech.activeRuns == 0 })
        #expect(h.controller.level == 0)
        #expect(h.controller.activeEngine == nil)
        await h.finish()
    }

    @Test func rapidTogglingLeavesOnePipeline() async throws {
        let h = try Harness()
        await h.controller.bootstrap()
        let controller = h.controller
        // Ruling R6: three tasks made in this order on the main actor, then awaited.
        let first = Task { await controller.start() }
        let second = Task { await controller.pause() }
        let third = Task { await controller.start() }
        await first.value
        await second.value
        await third.value
        #expect(await eventually { controller.state.isListening })
        await settle()
        #expect(controller.state.isListening)
        #expect(h.capture.startCount - h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 1)
        #expect(h.speech.activeRuns == 1)
        await h.finish()
    }

    @Test func rapidCommandsWhileListeningLeaveOnePipeline() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        let controller = h.controller
        let commands = [
            Task { await controller.pause() }, Task { await controller.toggle() }, Task { await controller.toggle() },
            Task { await controller.snooze(minutes: 5) }, Task { await controller.resume() },
        ]
        for command in commands { await command.value }
        #expect(await eventually { controller.state.isListening })
        h.sleeper.gate.open()  // the snooze's timer was superseded: it must not start anything
        await settle()
        #expect(controller.state.isListening)
        #expect(h.capture.startCount - h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 1)
        #expect(h.speech.activeRuns == 1)
        await h.finish()
    }

    @Test func rapidCommandsEndingInPauseLeaveNothingRunning() async throws {
        let h = try Harness()
        await h.controller.bootstrap()
        let controller = h.controller
        let commands = [
            Task { await controller.start() }, Task { await controller.toggle() }, Task { await controller.start() },
            Task { await controller.pause() },
        ]
        for command in commands { await command.value }
        #expect(controller.state == .off)
        await settle()
        #expect(controller.state == .off)
        #expect(h.capture.startCount == h.capture.stopCount)
        #expect(h.capture.activeRuns == 0)
        await h.finish()
    }

    @Test func pauseWhileCaptureIsStartingStopsIt() async throws {
        let h = try Harness(capture: FakeCapture([.init(startHangs: true), .init()]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.capture.startsInFlight == 1 })
        let pause = Task { await h.controller.pause() }
        await settle()
        h.capture.startGate.open()  // the start returns after the pause came in
        await pause.value
        #expect(h.controller.state == .off)
        #expect(h.capture.startCount == 1)
        #expect(h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 0)
        await h.controller.start()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.capture.activeRuns == 1)
        await h.finish()
    }

    @Test func toggleFollowsTheState() async throws {
        let h = try Harness()
        await h.controller.bootstrap()
        await h.controller.toggle()
        #expect(await eventually { h.controller.state.isListening })
        await h.controller.toggle()
        #expect(h.controller.state == .off)
        await h.controller.snooze(minutes: 5)
        await h.controller.toggle()
        #expect(h.controller.state == .off)
        h.sleeper.gate.open()
        await settle()
        #expect(h.controller.state == .off)
        #expect(h.capture.startCount == 1)
        await h.finish()
    }

    @Test func snoozeThenAutoResume() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.snooze(minutes: 15)
        #expect(h.controller.state == .snoozed(until: h.clock.now.addingTimeInterval(900)))
        #expect(h.capture.activeRuns == 0)
        #expect(await eventually { h.sleeper.durations.contains(.seconds(900)) })
        #expect(h.capture.startCount == 1)
        h.sleeper.gate.open()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.capture.startCount == 2)
        #expect(h.capture.activeRuns == 1)
        await h.finish()
    }

    @Test func pauseDuringSnoozeCancelsTheResume() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.snooze(minutes: 15)
        #expect(await eventually { h.sleeper.durations.contains(.seconds(900)) })
        await h.controller.pause()
        h.sleeper.gate.open()
        await settle()
        #expect(h.controller.state == .off)
        #expect(h.capture.startCount == 1)
        await h.finish()
    }

    // MARK: Calls

    @Test func duringCallsMode() async throws {
        let h = try Harness(configuration: .test(mode: .duringCalls))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .waitingForCall })
        #expect(await eventually { h.calls.subscriptions == 1 })
        #expect(h.capture.startCount == 0)
        h.calls.send(.active(["us.zoom.xos"]))
        #expect(await eventually { h.controller.state == .listening(systemAudioInfo) })
        h.calls.send(.inactive)
        #expect(await eventually { h.controller.state == .waitingForCall })
        #expect(h.capture.activeRuns == 0)
        #expect(h.capture.stopCount == 1)
        await h.finish()
    }

    @Test func duringCallsHoldsOneSubscriptionUntilPaused() async throws {
        let h = try Harness(configuration: .test(mode: .duringCalls))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .waitingForCall })
        #expect(await eventually { h.calls.subscriptions == 1 })
        h.calls.send(.inactive)
        h.calls.send(.active(["com.microsoft.teams2"]))
        #expect(await eventually { h.controller.state.isListening })
        h.calls.send(.inactive)
        #expect(await eventually { h.controller.state == .waitingForCall })
        h.calls.send(.active(["com.microsoft.teams2"]))
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.calls.subscriptions == 1)
        #expect(h.capture.startCount == 2)
        await h.controller.pause()
        #expect(await eventually { h.calls.terminations == 1 })
        #expect(h.capture.activeRuns == 0)
        await h.finish()
    }

    @Test func modeChangeEndsTheCallSubscription() async throws {
        let h = try Harness(configuration: .test(mode: .duringCalls))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .waitingForCall })
        #expect(await eventually { h.calls.subscriptions == 1 })
        await h.controller.update { $0.listening.mode = .always }
        #expect(await eventually { h.calls.terminations == 1 })
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.calls.subscriptions == 1)
        await h.finish()
    }

    @Test func duringCallsWithoutCallDetectionListensAllTheTime() async throws {
        let h = try Harness(configuration: .test(mode: .duringCalls), callDetectionSupported: false)
        #expect(await h.startListening())
        #expect(h.calls.subscriptions == 0)
        await h.finish()
    }

    // MARK: Failures and retries

    @Test func sourceFailureRestartsWithBackoff() async throws {
        let h = try Harness(
            sleeper: TestSleeper(gatedFrom: .zero),
            capture: FakeCapture([.init(chunks: 1, ending: .fail("The microphone was unplugged")), .init()]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .error(.captureFailed("The microphone was unplugged")) })
        #expect(await eventually { h.sleeper.durations == [.milliseconds(1)] })
        h.sleeper.gate.open()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.capture.startCount == 2)
        #expect(h.capture.activeRuns == 1)
        #expect(h.capture.madeKinds == [.systemAudio, .systemAudio])
        await h.finish()
    }

    @Test func engineFailureRestartsWithBackoff() async throws {
        let h = try Harness(
            sleeper: TestSleeper(gatedFrom: .zero),
            speech: FakeSpeech([.init(failAfterChunks: 1, failure: .engineFailed("The recognizer crashed")), .init()]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .error(.engineFailed("The recognizer crashed")) })
        h.sleeper.gate.open()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.speech.prepareCount == 2)
        #expect(h.capture.startCount == 2)
        #expect(h.capture.activeRuns == 1)
        await h.finish()
    }

    @Test func backoffDoublesUpToThirtyTimesTheBase() async throws {
        let h = try Harness(capture: FakeCapture([.init(chunks: 0, ending: .fail("Gone"))]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.sleeper.durations.count >= 8 })
        await h.controller.pause()
        let expected: [Duration] = [1, 2, 4, 8, 16, 30, 30, 30].map { .milliseconds($0) }
        #expect(Array(h.sleeper.durations.prefix(8)) == expected)
        #expect(h.capture.activeRuns == 0)
        await h.finish()
    }

    @Test func aMinuteOfHealthyListeningResetsTheBackoff() async throws {
        let h = try Harness(
            capture: FakeCapture([
                .init(chunks: 0, ending: .fail("Gone")), .init(chunks: 1, ending: .failWhenTriggered("Gone again")),
                .init(),
            ]))
        #expect(await h.startListening())
        #expect(h.sleeper.durations == [.milliseconds(1)])
        h.clock.advance(by: 61)
        h.capture.failTrigger.open()
        #expect(await eventually { h.capture.startCount == 3 && h.controller.state.isListening })
        #expect(h.sleeper.durations == [.milliseconds(1), .milliseconds(1)])
        await h.finish()
    }

    @Test func hungCaptureStartIsAbandonedForAFreshSource() async throws {
        let h = try Harness(capture: FakeCapture([.init(startHangs: true), .init()]), captureCallLimit: .milliseconds(50))
        #expect(await h.startListening())
        #expect(h.capture.madeKinds.count == 2)
        #expect(h.sleeper.durations == [.milliseconds(1)])
        h.capture.startGate.open()
        // The abandoned start returns at last, and that capture is stopped straight away.
        #expect(await eventually { h.capture.stopCount == 1 && h.capture.activeRuns == 1 })
        #expect(h.controller.state.isListening)
        await h.finish()
    }

    @Test func userStoppedCaptureDoesNotRetry() async throws {
        let h = try Harness(capture: FakeCapture([.init(chunks: 1, ending: .stoppedByUser), .init()]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.capture.startCount == 1 && h.controller.state == .off })
        await settle()
        #expect(h.controller.state == .off)
        #expect(h.capture.startCount == 1)
        #expect(h.capture.activeRuns == 0)
        #expect(h.sleeper.durations.isEmpty)
        await h.finish()
    }

    @Test func aFinalJustAfterTheAudioEndsStillCounts() async throws {
        let h = try Harness(
            capture: FakeCapture([.init(chunks: 1, ending: .stoppedByUser)]),
            speech: FakeSpeech([.init(late: final("s1", "hey Bala"))]))  // 50 ms after the audio ends
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.channel.hits.count == 1 })
        #expect(await eventually { h.controller.state == .off })  // the user stopped capture: no retry
        #expect(h.controller.recentHits.map(\.term) == ["Bala"])
        #expect(h.capture.startCount == 1)
        await h.finish()
    }

    @Test func waitingForTheLastWordsIsBounded() async throws {
        let h = try Harness(
            capture: FakeCapture([.init(chunks: 1, ending: .stoppedByUser)]),
            speech: FakeSpeech([.init(staysOpenAfterAudio: true)]))
        h.controller.transcriptDrainLimit = .milliseconds(100)
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.capture.startCount == 1 && h.controller.state == .off })
        #expect(await eventually { h.speech.activeRuns == 0 })  // its stream was let go
        #expect(h.speech.stopCount == 1)
        #expect(h.capture.activeRuns == 0)
        await h.finish()
    }

    @Test func restartDoesNotSuppressFirstMention() async throws {
        let h = try Harness(
            capture: FakeCapture([.init(chunks: 1, ending: .failWhenTriggered("Output device changed")), .init()]),
            speech: FakeSpeech([.init([final("s1", "Bala")])]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.channel.hits.count == 1 })
        h.clock.advance(by: 11)  // past the rule's 10 s cooldown and the 3 s global one
        h.capture.failTrigger.open()
        #expect(await eventually { h.channel.hits.count == 2 })
        #expect(h.channel.hits.map(\.segmentID) == ["s1", "s1"])
        #expect(h.capture.startCount == 2)
        await h.finish()
    }

    // MARK: Permissions, engines and models

    @Test func permissionDeniedNoRetry() async throws {
        let h = try Harness(permissions: PermissionsSnapshot.allGranted.with(.screenRecording, .denied))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .error(.permissionDenied(.screenRecording)) })
        await settle()
        #expect(h.controller.state == .error(.permissionDenied(.screenRecording)))
        #expect(h.capture.madeKinds.isEmpty)
        #expect(h.sleeper.durations.isEmpty)
        await h.finish()
    }

    @Test func grantingTheMissingPermissionStartsOnRefresh() async throws {
        let h = try Harness(permissions: PermissionsSnapshot.allGranted.with(.microphone, .notDetermined))
        await h.controller.bootstrap()
        await h.controller.update { $0.listening.source = .microphone }
        await h.controller.start()
        #expect(await eventually { h.controller.state == .error(.permissionDenied(.microphone)) })
        h.permissions.set(.microphone, .granted)
        await h.controller.refreshPermissions()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.controller.permissions.microphone == .granted)
        await h.finish()
    }

    @Test func captureRefusedDespiteThePermissionAsksForARelaunch() async throws {
        let h = try Harness(capture: FakeCapture([.init(startError: .permissionDenied)]))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .error(.permissionDenied(.screenRecording)) })
        #expect(h.controller.warnings.contains(.screenRecordingNeedsRelaunch))
        await h.controller.refreshPermissions()  // granted, but only a relaunch helps: no new attempt
        await settle()
        #expect(h.capture.startCount == 1)
        #expect(h.sleeper.durations.isEmpty)
        await h.finish()
    }

    @Test func speechPermissionIsNeededOnlyBySFSpeech() async throws {
        let denied = PermissionsSnapshot.allGranted.with(.speechRecognition, .denied)

        let analyzer = try Harness(capabilities: .analyzer, permissions: denied)
        #expect(await analyzer.startListening())
        #expect(analyzer.controller.requiredPermissions() == [.screenRecording])
        await analyzer.finish()

        let sfSpeech = try Harness(capabilities: .sfSpeechOnly, permissions: denied)
        await sfSpeech.controller.bootstrap()
        await sfSpeech.controller.start()
        #expect(await eventually { sfSpeech.controller.state == .error(.permissionDenied(.speechRecognition)) })
        #expect(sfSpeech.controller.requiredPermissions() == [.screenRecording, .speechRecognition])
        #expect(sfSpeech.capture.madeKinds.isEmpty)
        await sfSpeech.finish()
    }

    @Test func engineUnavailableIsAnErrorWithoutRetry() async throws {
        let h = try Harness(capabilities: .noAppleSpeech)
        await h.controller.bootstrap()
        await h.controller.update { $0.speech.engine = .apple }
        await h.controller.start()
        #expect(await eventually {
            if case .error(.engineUnavailable) = h.controller.state { true } else { false }
        })
        // "Use local model" fixes it.
        await h.controller.update { $0.speech.engine = .localModel }
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.speech.madeIDs == [.whisperLight])
        await h.finish()
    }

    @Test func appleAssetProgressShowsWhilePreparing() async throws {
        let speech = FakeSpeech(holdsPrepare: true)
        speech.reportWhilePreparing([PreparationProgress(stage: .installingAppleAssets, fraction: 0.4)])
        let h = try Harness(speech: speech)
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state == .preparing(.installingAppleAssets(0.4)) })
        speech.prepareGate.open()
        #expect(await eventually { h.controller.state.isListening })
        await h.finish()
    }

    @Test func pauseDoesNotWaitForASlowPreparation() async throws {
        let speech = FakeSpeech(holdsPrepare: true)
        let h = try Harness(speech: speech)
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { speech.prepareCount == 1 })
        await h.controller.pause()  // returns although the preparation is still going
        #expect(h.controller.state == .off)
        #expect(speech.stopCount == 0)
        speech.prepareGate.open()
        // The preparation ends by itself later, and its engine is stopped then; capture never started.
        #expect(await eventually { speech.stopCount == 1 })
        await settle()
        #expect(h.capture.madeKinds.isEmpty)
        #expect(h.controller.state == .off)
        await h.finish()
    }

    @Test func downloadsMissingModel() async throws {
        let h = try Harness(capabilities: .noAppleSpeech, models: FakeModels(installed: [], holdsDownloads: true))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.controller.state.isDownloadingModel })
        #expect(h.controller.modelDownloads[.lightEnglish] != nil)
        h.models.releaseDownloads()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.models.downloads == [.lightEnglish, .vad])
        #expect(h.controller.installedModels.isSuperset(of: [.lightEnglish, .vad]))
        #expect(h.controller.modelDownloads.isEmpty)
        #expect(h.speech.madeIDs == [.whisperLight])
        await h.finish()
    }

    @Test func deletingTheModelWhileItDownloadsIsModelMissing() async throws {
        let h = try Harness(capabilities: .noAppleSpeech, models: FakeModels(installed: [], holdsDownloads: true))
        await h.controller.bootstrap()
        await h.controller.start()
        #expect(await eventually { h.models.heldDownloads == 1 })
        try await h.controller.deleteModel(.lightEnglish)
        #expect(await eventually { h.controller.state == .error(.modelMissing) })
        await settle()
        #expect(h.controller.state == .error(.modelMissing))
        #expect(h.capture.madeKinds.isEmpty)
        #expect(h.sleeper.durations.isEmpty)
        await h.finish()
    }

    @Test func aModelInUseCannotBeDeleted() async throws {
        let h = try Harness(capabilities: .noAppleSpeech)
        #expect(await h.startListening())
        await #expect(throws: ListeningControllerError.modelInUse) {
            try await h.controller.deleteModel(.lightEnglish)
        }
        #expect(h.models.deletes.isEmpty)
        try await h.controller.deleteModel(.balancedEnglish)
        #expect(h.models.deletes == [.balancedEnglish])
        #expect(!h.controller.installedModels.contains(.balancedEnglish))
        await h.finish()
    }

    @Test func downloadModelFetchesTheDetectorToo() async throws {
        let h = try Harness(models: FakeModels(installed: []))
        await h.controller.bootstrap()
        #expect(h.controller.installedModels.isEmpty)
        try await h.controller.downloadModel(.balancedEnglish)
        #expect(h.models.downloads == [.balancedEnglish, .vad])
        #expect(h.controller.installedModels == [.balancedEnglish, .vad])
        #expect(h.controller.modelDownloads.isEmpty)
        await h.finish()
    }

    @Test func fallingBehindWarningClearsWhenThePipelineStartsOver() async throws {
        let h = try Harness(
            capabilities: .noAppleSpeech,
            capture: FakeCapture([.init(chunks: 1, ending: .failWhenTriggered("Output device changed")), .init()]))
        #expect(await h.startListening())
        h.controller.noteLocalModelFallingBehind()
        #expect(h.controller.warnings == [.localModelFallingBehind])
        h.capture.failTrigger.open()
        #expect(await eventually { h.capture.startCount == 2 && h.controller.state.isListening })
        #expect(h.controller.warnings.isEmpty)
        await h.finish()
    }

    @Test func fallingBehindWarningClearsAfterTwoQuietMinutes() async throws {
        let h = try Harness(capabilities: .noAppleSpeech)
        #expect(await h.startListening())
        h.controller.noteLocalModelFallingBehind()
        #expect(await eventually { h.sleeper.durations == [.seconds(120)] })
        h.controller.noteLocalModelFallingBehind()  // another report starts the two minutes again
        #expect(await eventually { h.sleeper.durations == [.seconds(120), .seconds(120)] })
        #expect(await eventually { h.sleeper.cancellations == 1 })
        #expect(h.controller.warnings == [.localModelFallingBehind])
        h.sleeper.gate.open()  // two minutes without another report
        #expect(await eventually { h.controller.warnings.isEmpty })
        #expect(h.controller.state.isListening)
        await h.finish()
    }

    @Test func fallingBehindWarningIsClearedByAnotherModelSize() async throws {
        let h = try Harness(capabilities: .noAppleSpeech)
        #expect(await h.startListening())
        h.controller.noteLocalModelFallingBehind()
        #expect(h.controller.warnings == [.localModelFallingBehind])
        await h.controller.update { $0.speech.localModelSize = .balanced }
        #expect(h.controller.warnings.isEmpty)
        #expect(await eventually { h.speech.madeIDs == [.whisperLight, .whisperBalanced] })
        await h.finish()
    }

    // MARK: Settings

    @Test func sourceChangeRestarts() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.update { $0.listening.source = .microphone }
        #expect(await eventually {
            h.controller.state
                == .listening(ListeningInfo(engine: .appleSpeechTranscriber, source: .microphone, localeIdentifier: "en-US"))
        })
        #expect(h.capture.madeKinds == [.systemAudio, .microphone])
        #expect(h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 1)
        await h.finish()
    }

    @Test func ruleChangeUpdatesHintsWithoutRestart() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.update { $0.rules.append(Rule(name: "Surname", terms: ["Kumar"], channels: [.sound])) }
        #expect(h.speech.hintUpdates == [["Bala", "Kumar"]])
        #expect(h.capture.startCount == 1)
        #expect(h.controller.state.isListening)
        await h.finish()
    }

    @Test func historyIsSkippedWhenTurnedOff() async throws {
        let h = try Harness(configuration: .test(history: false), speech: heyBala())
        #expect(await h.startListening())
        #expect(await eventually { h.controller.recentHits.count == 1 })
        #expect(await h.controller.history().isEmpty)
        await h.finish()
    }

    // MARK: Sleep

    @Test func sleepWake() async throws {
        let h = try Harness()
        #expect(await h.startListening())
        await h.controller.systemWillSleep()
        #expect(h.capture.stopCount == 1)
        #expect(h.capture.activeRuns == 0)
        #expect(h.controller.state == .off)
        await h.controller.systemDidWake()
        #expect(await eventually { h.sleeper.durations.contains(.seconds(2)) })
        #expect(h.capture.startCount == 1)
        h.sleeper.gate.open()
        #expect(await eventually { h.controller.state.isListening })
        #expect(h.capture.startCount == 2)
        await h.finish()
    }

    @Test func wakeAfterSleepingWhileOffStaysOff() async throws {
        let h = try Harness()
        await h.controller.bootstrap()
        await h.controller.systemWillSleep()
        await h.controller.systemDidWake()
        h.sleeper.gate.open()
        await settle()
        #expect(h.controller.state == .off)
        #expect(h.sleeper.durations.isEmpty)
        #expect(h.capture.startCount == 0)
        await h.finish()
    }

    @Test func sleepWritesConfigurationAndHistory() async throws {
        let h = try Harness(speech: heyBala())
        #expect(await h.startListening())
        #expect(await eventually { await h.controller.history().count == 1 })
        await h.controller.update { $0.globalCooldownSeconds = 7 }
        #expect(try h.hitsOnDisk() == 0)  // both stores wait a minute before writing
        await h.controller.systemWillSleep()
        #expect(try h.hitsOnDisk() == 1)
        #expect(try h.configurationOnDisk().globalCooldownSeconds == 7)
        await h.finish()
    }

    @Test func sleepWritesBeforeStoppingACaptureThatHangs() async throws {
        let h = try Harness(capture: FakeCapture([.init(stopHangs: true)]), speech: heyBala())
        #expect(await h.startListening())
        #expect(await eventually { await h.controller.history().count == 1 })
        await h.controller.update { $0.globalCooldownSeconds = 7 }
        #expect(try h.hitsOnDisk() == 0)  // both stores wait a minute before writing
        let sleep = Task { await h.controller.systemWillSleep() }
        #expect(await eventually { h.capture.stopsInFlight == 1 })  // stopping capture hangs...
        #expect(try h.hitsOnDisk() == 1)  // ...and both stores were written before it
        #expect(try h.configurationOnDisk().globalCooldownSeconds == 7)
        h.capture.stopGate.open()
        await sleep.value
        #expect(h.controller.state == .off)
        #expect(h.capture.activeRuns == 0)
        await h.finish()
    }

    // MARK: Alerts

    @Test func hitCarriesExcerpt() async throws {
        let h = try Harness(
            capture: FakeCapture([.init(chunks: 2)]),
            speech: FakeSpeech([.init([final("s1", "we were talking about the budget"), final("s2", "Bala, what do you think")])]))
        #expect(await h.startListening())
        #expect(await eventually { h.channel.hits.count == 1 })
        let excerpt = try #require(h.channel.hits.first?.excerpt)
        #expect(excerpt == "we were talking about the budget Bala, what do you think")
        #expect(await eventually { h.controller.recentHits.count == 1 })
        #expect(h.controller.recentHits.first?.excerpt == excerpt)
        await h.finish()
    }

    @Test func hitIsRecordedBeforeSlowChannelsFinish() async throws {
        let channel = FakeChannel(.sound, holdsDeliveries: true)  // as slow as the test wants
        let h = try Harness(speech: heyBala(), channel: channel)
        #expect(await h.startListening())
        #expect(await eventually { h.controller.recentHits.count == 1 })
        #expect(h.controller.lastHitAt == h.clock.now)
        #expect(await h.controller.history().count == 1)
        #expect(await eventually { channel.hits.count == 1 })
        #expect(channel.finished == 0)  // recorded while its delivery still waits
        #expect(h.controller.deliveriesUnderWay == 1)

        channel.gate.open()
        #expect(await eventually { h.controller.deliveriesUnderWay == 0 })
        #expect(channel.finished == 1)
        // Recorded and delivered once each.
        #expect(h.controller.recentHits.count == 1)
        #expect(await h.controller.history().count == 1)
        #expect(channel.hits.count == 1)
        await h.finish()
    }

    @Test func aPauseDoesNotStopTheDeliveriesOfHitsHeardBeforeIt() async throws {
        let channel = FakeChannel(.sound, holdsDeliveries: true)
        let h = try Harness(speech: heyBala(), channel: channel)
        #expect(await h.startListening())
        #expect(await eventually { channel.hits.count == 1 })
        await h.controller.pause()
        #expect(h.controller.state == .off)
        #expect(h.controller.deliveriesUnderWay == 1)

        channel.gate.open()
        #expect(await eventually { h.controller.deliveriesUnderWay == 0 })
        #expect(channel.finished == 1)
        #expect(channel.cancelled == 0)
        #expect(h.controller.recentHits.count == 1)
        await h.finish()
    }

    @Test func aHitHeldBackByTheGlobalCooldownIsNeitherRecordedNorDelivered() async throws {
        let surname = Rule(name: "Surname", terms: ["Kumar"], channels: [.sound])
        let h = try Harness(
            configuration: .test(rules: [bala, surname]), capture: FakeCapture([.init(chunks: 2)]),
            speech: FakeSpeech([.init([final("s1", "hey Bala"), final("s2", "and Kumar")])]))
        #expect(await h.startListening())
        #expect(await eventually { h.channel.hits.count == 1 })
        #expect(await eventually { h.controller.deliveriesUnderWay == 0 })
        await settle()
        // "Kumar" is another rule's, but it came within the 3 s global cooldown (the test's clock stands still).
        #expect(h.channel.hits.map(\.term) == ["Bala"])
        #expect(h.controller.recentHits.map(\.term) == ["Bala"])
        #expect(await h.controller.history().count == 1)
        #expect(h.controller.liveTranscript == "hey Bala and Kumar")
        await h.finish()
    }

    @Test func testAlertSendsASampleHitToOneChannel() async throws {
        let h = try Harness()
        await h.controller.bootstrap()
        try await h.controller.testAlert(.sound)
        let hit = try #require(h.channel.hits.last)
        #expect(hit.ruleID == bala.id)
        #expect(hit.ruleName == "Test")
        #expect(hit.term == "Bala")
        #expect(hit.matchedText == "Bala")
        #expect(hit.context == "This is a test alert from Takeheed.")
        #expect(hit.timestamp == h.clock.now)
        #expect(hit.source == .systemAudio)
        #expect(hit.engine == .appleSFSpeech)
        #expect(hit.segmentID == "test")
        await #expect(throws: AlertDeliveryError.noChannel(.ntfy)) {
            try await h.controller.testAlert(.ntfy)
        }
        #expect(await h.controller.lastDeliveryFailures()[.ntfy] == nil)
        await h.finish()
    }

    @Test func clearHistoryForgetsRecentHits() async throws {
        let h = try Harness(speech: heyBala())
        #expect(await h.startListening())
        #expect(await eventually { await h.controller.history().count == 1 })
        await h.controller.clearHistory()
        #expect(await h.controller.history().isEmpty)
        #expect(h.controller.recentHits.isEmpty)
        await h.finish()
    }

    // MARK: The level meter

    @Test func levelIsOnADecibelScale() {
        #expect(ListeningController.level(rms: 1) == 1)  // full scale, 0 dBFS
        #expect(abs(ListeningController.level(rms: 0.1) - 2.0 / 3) < 1e-6)  // −20 dBFS
        #expect(abs(ListeningController.level(rms: 0.01) - 1.0 / 3) < 1e-6)  // −40 dBFS
        #expect(ListeningController.level(rms: 0.001) < 1e-6)  // −60 dBFS
        #expect(ListeningController.level(rms: 0.0001) == 0)  // quieter than that
        #expect(ListeningController.level(rms: 0) == 0)  // silence
        #expect(ListeningController.level(rms: 2) == 1)  // past full scale
        #expect(ListeningController.level(rms: .nan) == 0)
    }
}

// MARK: - What was heard lately

@Suite("ListeningController transcript")
struct ListeningControllerTranscriptTests {
    private let start = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func liveTranscriptShowsFinalsThenTheVolatileText() {
        var memory = TranscriptMemory()
        memory.take(partial("a", "hey"), at: start)
        #expect(memory.live == "hey")
        memory.take(final("a", "hey Bala"), at: start)
        memory.take(partial("b", "what do"), at: start)
        #expect(memory.live == "hey Bala what do")
        memory.take(final("b", "what do you think"), at: start)
        #expect(memory.live == "hey Bala what do you think")
    }

    @Test func liveTranscriptKeepsTheLastThreeHundredCharacters() {
        var memory = TranscriptMemory()
        for index in 0..<40 { memory.take(final("s\(index)", "word number \(index)"), at: start) }
        #expect(memory.live.count == 300)
        #expect(memory.live.hasSuffix("word number 39"))
    }

    @Test func excerptKeepsHalfAMinuteOfFinalsBeforeTheMatch() {
        var memory = TranscriptMemory()
        memory.take(final("1", "long ago"), at: start)
        memory.take(final("2", "we were talking about the budget"), at: start.addingTimeInterval(20))
        let excerpt = memory.excerpt(endingWith: "Bala, what do you think", at: start.addingTimeInterval(40))
        #expect(excerpt == "we were talking about the budget Bala, what do you think")
    }

    @Test func excerptKeepsTheLastSixHundredCharacters() {
        var memory = TranscriptMemory()
        memory.take(final("1", String(repeating: "blah ", count: 200)), at: start)
        let excerpt = memory.excerpt(endingWith: "Bala", at: start)
        #expect(excerpt?.count == 600)
        #expect(excerpt?.hasPrefix("\u{2026}") == true)
        #expect(excerpt?.hasSuffix("blah Bala") == true)
    }

    @Test func excerptIsNilWhenNothingWasHeard() {
        let memory = TranscriptMemory()
        #expect(memory.excerpt(endingWith: "  ", at: start) == nil)
    }
}

// MARK: - Pro

private let alpha = Rule(name: "Alpha", terms: ["Alpha"], channels: [.sound])
private let bravo = Rule(name: "Bravo", terms: ["Bravo"], channels: [.sound])
private let charlie = Rule(name: "Charlie", terms: ["Charlie"], channels: [.sound])
private let delta = Rule(name: "Delta", terms: ["Delta"], channels: [.sound])

/// The engine hears "hey Delta", the fourth rule's word, on the first chunk.
private func heyDelta() -> FakeSpeech {
    FakeSpeech([.init([final("s1", "hey Delta")])])
}

@MainActor
@Suite("ListeningController Pro access", .timeLimit(.minutes(1)))
struct ListeningControllerProTests {
    private static var fourRules: AppConfiguration { .test(rules: [alpha, bravo, charlie, delta]) }

    /// `fourRules`, with the first rule also alerting through ntfy, which has a topic.
    private static var fourRulesWithNtfy: AppConfiguration {
        var configuration = fourRules
        configuration.rules[0].channels = [.sound, .ntfy]
        configuration.channels.ntfy.topic = "alerts"
        return configuration
    }

    @Test func freeHoldsBackTheFourthRule() async throws {
        let h = try Harness(configuration: Self.fourRules, speech: heyDelta(), proAccess: .free)
        #expect(await h.startListening())
        await settle()
        #expect(h.channel.hits.isEmpty)
        #expect(await h.controller.history().isEmpty, "a held-back rule adds nothing to History")
        #expect(h.speech.preparedHints == [["Alpha", "Bravo", "Charlie"]])
        await h.finish()
    }

    @Test func proAlertsWithEveryRule() async throws {
        let h = try Harness(configuration: Self.fourRules, speech: heyDelta(), proAccess: .pro)
        #expect(await h.startListening())
        #expect(await eventually { h.channel.hits.count == 1 })
        #expect(h.channel.hits.first?.ruleName == "Delta")
        #expect(h.speech.preparedHints == [["Alpha", "Bravo", "Charlie", "Delta"]])
        await h.finish()
    }

    @Test func buyingProReachesTheRunningEngineWithoutARestart() async throws {
        let h = try Harness(configuration: Self.fourRules, proAccess: .free)
        #expect(await h.startListening())
        await h.controller.setProAccess(.pro)
        #expect(h.controller.proAccess == .pro)
        #expect(h.controller.proPolicy.isPro)
        #expect(h.speech.hintUpdates.last == ["Alpha", "Bravo", "Charlie", "Delta"])
        #expect(h.capture.startCount == 1, "listening was not restarted")
        await h.finish()
    }

    @Test func losingProHoldsBackAndKeepsEverythingSaved() async throws {
        let configuration = Self.fourRulesWithNtfy
        let h = try Harness(configuration: configuration, proAccess: .pro)
        #expect(await h.startListening())
        await h.controller.setProAccess(.free)
        #expect(h.speech.hintUpdates.last == ["Alpha", "Bravo", "Charlie"])
        #expect(h.capture.startCount == 1)
        #expect(h.controller.configuration.rules == configuration.rules, "nothing the user set up changes")
        #expect(h.controller.configuration.channels == configuration.channels)
        await h.finish()
    }

    @Test func freeSendsNoAlertThatLeavesTheMacButStillRecordsTheHit() async throws {
        var configuration = AppConfiguration.test(rules: [Rule(name: "My name", terms: ["Bala"], channels: [.sound, .ntfy])])
        configuration.channels.ntfy.topic = "alerts"
        let h = try Harness(configuration: configuration, speech: heyBala(), channel: FakeChannel(.ntfy), proAccess: .free)
        #expect(await h.startListening())
        #expect(await eventually { await h.controller.history().count == 1 })
        await settle()
        #expect(h.channel.hits.isEmpty, "ntfy is part of Pro")
        await h.finish()
    }

    @Test func freeDeliversTheAlertsThatStayOnTheMacAndNotTheOthers() async throws {
        var configuration = AppConfiguration.test(rules: [Rule(name: "My name", terms: ["Bala"], channels: [.sound, .ntfy])])
        configuration.channels.ntfy.topic = "alerts"
        let ntfy = FakeChannel(.ntfy)
        let h = try Harness(
            configuration: configuration, speech: heyBala(), channel: FakeChannel(.sound), otherChannels: [ntfy],
            proAccess: .free)
        #expect(await h.startListening())
        #expect(await eventually { h.channel.hits.count == 1 })
        await settle()
        #expect(h.channel.hits.count == 1, "one delivery to Sound")
        #expect(ntfy.hits.isEmpty, "none to ntfy, which is part of Pro")
        await h.finish()
    }

    @Test func aTestOfAnAlertThatStaysOnTheMacWorksOnFree() async throws {
        let h = try Harness(channel: FakeChannel(.sound), proAccess: .free)
        await h.controller.bootstrap()
        try await h.controller.testAlert(.sound)
        #expect(h.channel.hits.count == 1)
        await h.finish()
    }

    @Test func proSendsTheAlertsThatLeaveTheMac() async throws {
        var configuration = AppConfiguration.test(rules: [Rule(name: "My name", terms: ["Bala"], channels: [.sound, .ntfy])])
        configuration.channels.ntfy.topic = "alerts"
        let h = try Harness(configuration: configuration, speech: heyBala(), channel: FakeChannel(.ntfy), proAccess: .pro)
        #expect(await h.startListening())
        #expect(await eventually { h.channel.hits.count == 1 })
        await h.finish()
    }

    @Test func aTestOfAnAlertThatLeavesTheMacNeedsPro() async throws {
        var configuration = AppConfiguration.test()
        configuration.channels.ntfy.topic = "alerts"
        let h = try Harness(configuration: configuration, channel: FakeChannel(.ntfy), proAccess: .free)
        await h.controller.bootstrap()
        await #expect(throws: ProFeatureError.needsPro(.ntfy)) {
            try await h.controller.testAlert(.ntfy)
        }
        #expect(h.channel.hits.isEmpty)
        await h.controller.setProAccess(.pro)
        try await h.controller.testAlert(.ntfy)
        #expect(h.channel.hits.count == 1)
        await h.finish()
    }

    @Test func freeAddsRulesUpToTheLimitOnly() async throws {
        let h = try Harness(configuration: .test(rules: [alpha, bravo]), proAccess: .free)
        await h.controller.bootstrap()
        #expect(await h.controller.addRule(charlie))
        let addedPastTheLimit = await h.controller.addRule(delta)
        #expect(!addedPastTheLimit)
        #expect(h.controller.configuration.rules.map(\.name) == ["Alpha", "Bravo", "Charlie"])
        await h.controller.setProAccess(.pro)
        #expect(await h.controller.addRule(delta))
        #expect(h.controller.configuration.rules.count == 4)
        await h.controller.systemWillSleep()  // writes the configuration now
        #expect(try h.configurationOnDisk().rules.count == 4)
        await h.finish()
    }

    @Test func twoQuickAddsAtTheLimitAddOneRule() async throws {
        let h = try Harness(configuration: .test(rules: [alpha, bravo]), proAccess: .free)
        await h.controller.bootstrap()
        let controller = h.controller
        let first = Task { await controller.addRule(charlie) }
        let second = Task { await controller.addRule(delta) }
        let results = [await first.value, await second.value]
        #expect(results.filter { $0 }.count == 1)
        #expect(controller.configuration.rules.count == 3)
        await h.finish()
    }

    @Test func aDemoControllerCanShowFree() {
        let controller = ListeningController.demo(
            configuration: .test(rules: [alpha, bravo, charlie, delta]), state: .off, recentHits: [], liveTranscript: "",
            level: 0, proAccess: .free)
        #expect(controller.proAccess == .free)
        #expect(controller.proPolicy.heldBackRuleIDs(in: controller.configuration.rules) == [delta.id])
    }
}
