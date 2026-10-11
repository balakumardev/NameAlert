import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech
import Observation
import os

/// Why the controller turned down a request.
public enum ListeningControllerError: Error, Equatable, Sendable {
    /// The model is used by the engine that is listening, so it cannot be deleted now.
    case modelInUse
}

extension ListeningControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelInUse: "This model is in use. Pause listening or pick another model before deleting it."
        }
    }
}

/// Listens, and alerts when a rule's words are heard. Everything the UI shows about listening is here.
///
/// **Commands.** `bootstrap`, `start`, `pause`, `toggle`, `snooze`, `resume`, `update`, `completeOnboarding`,
/// `systemWillSleep` and `systemDidWake` change what the controller does. They run one at a time, in the order they
/// were called: each waits until the commands before it are over, so two can never interleave, and after any burst
/// of them the state is the one the last command asked for. A command takes its place in the line before it first
/// waits for anything, so calls made one after another on the main actor run in that order. Commands are short: what
/// lasts (listening, the snooze timer, the pause after waking) runs in a *session*, a task the command starts and the
/// next command that changes what is going on cancels and waits for. A command therefore returns once that work is
/// stopped or started, never after a whole snooze or download. The other methods read state or do one self-contained
/// thing (send a test alert, download a model); they are not part of the line.
///
/// **Listening.** A listening session makes attempts. Each attempt checks the permissions, picks the engine, downloads
/// a missing local model, gets a new engine ready, starts a new capture source and runs the pipeline: audio chunks go
/// to the engine (and set `level`), the engine's text goes to the rule engine (and `liveTranscript`), and each hit the
/// alert dispatcher admits is recorded at once (`recentHits`, the history), then delivered while listening goes on.
/// When capture or the engine fails, the attempt ends and the next one follows after a pause: `backoffBase`, then twice
/// that after the next failure in a row, up to 30 times it; a minute of listening starts the count again. A permission
/// that is missing, an engine that cannot be had, or a model that could not be downloaded ends the session instead: the
/// user must act. In "Only during calls" mode the session waits for a call (one subscription to the call state for the
/// whole session) and makes its attempts while it lasts.
///
/// **Stopping.** Everything an attempt started is stopped before it ends: capture first, then the engine. A capture
/// source that does not answer `start()` or `stop()` within `captureCallLimit` is left behind (and stopped if its
/// start ever returns); the next attempt makes a new one.
@MainActor
@Observable
public final class ListeningController {
    // MARK: What the UI shows

    public private(set) var configuration: AppConfiguration
    public private(set) var state: ListeningState = .off
    /// The audio level while listening, from 0 (−60 dBFS or quieter) to 1 (full scale), at most 15 times a second; 0
    /// otherwise.
    public private(set) var level: Double = 0
    /// The last 300 characters heard: the final text, then what the engine is still working on. Kept in memory only.
    public private(set) var liveTranscript = ""
    /// The newest hits that were sent on, newest first, at most 5.
    public private(set) var recentHits: [Hit] = []
    /// The engine of the listening session, once it is picked.
    public private(set) var activeEngine: EngineID?
    public private(set) var warnings: Set<RuntimeWarning> = []
    public private(set) var permissions: PermissionsSnapshot = .undetermined
    /// The models being downloaded, and how far along each is, from 0 to 1.
    public private(set) var modelDownloads: [WhisperModel: Double] = [:]
    public private(set) var installedModels: Set<WhisperModel> = []
    /// When the newest hit that was sent on was heard.
    public private(set) var lastHitAt: Date?

    // MARK: Collaborators

    private let dependencies: RuntimeDependencies
    private let dispatcher: AlertDispatcher
    private let commands = CommandQueue()
    private let logger = Log.logger("runtime")
    @ObservationIgnored private var ruleEngine = RuleEngine(rules: [])
    @ObservationIgnored private var memory = TranscriptMemory()

    // MARK: Sessions

    /// The latest session a command started. Its work may be over (a timer that fired, a session that ended in an
    /// error); a command that ends it waits for it all the same.
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var sessionCount: UInt64 = 0
    /// Listening was stopped for sleep, and starts again after waking.
    @ObservationIgnored private var resumesAfterWake = false
    @ObservationIgnored private var isConfigurationLoaded = false
    @ObservationIgnored private var isBootstrapped = false
    /// The latest engine pick, for `requiredPermissions()`.
    @ObservationIgnored private var lastResolution: EngineResolution?

    // MARK: The attempt that is running

    /// The engine of the attempt that is running, from its creation until it is stopped. Rule changes go to it.
    @ObservationIgnored private var currentEngine: (any SpeechEngine)?
    /// The models the running attempt's engine uses: they cannot be deleted.
    @ObservationIgnored private var modelsInUse: Set<WhisperModel> = []
    @ObservationIgnored private var progressPhases: UInt64 = 0
    /// The download or preparation whose progress `state` shows. Progress from any other is late and ignored.
    @ObservationIgnored private var shownProgressPhase: UInt64?
    /// How many downloads of each model are running, so that `modelDownloads` drops a model when the last is over.
    @ObservationIgnored private var downloadCounts: [WhisperModel: Int] = [:]

    // MARK: Alerts on their way

    /// The deliveries of admitted hits that are not over yet, each in a task of its own that removes itself when it
    /// ends (within the dispatcher's delivery timeout). Nothing cancels them: their hits were heard before any pause.
    @ObservationIgnored private var deliveries: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var deliveryCount: UInt64 = 0

    /// Clears `.localModelFallingBehind` once the local model has kept up for a while (see
    /// `noteLocalModelFallingBehind`).
    @ObservationIgnored private var fallingBehindExpiry: Task<Void, Never>?

    /// How long a capture source's `start()`, `stop()` and `endReason()`, and an engine's `stop()`, may take before the
    /// controller stops waiting and leaves that object behind. Tests shorten it.
    @ObservationIgnored var captureCallLimit: Duration = .seconds(10)
    /// How long the engine may go on reporting after the audio ended by itself, so that the final result for the last
    /// words still counts. Tests shorten it.
    @ObservationIgnored var transcriptDrainLimit: Duration = .seconds(2)

    public init(dependencies: RuntimeDependencies) {
        self.dependencies = dependencies
        configuration = AppConfiguration()
        dispatcher = AlertDispatcher(channels: dependencies.channels, secrets: dependencies.secrets, now: dependencies.now)
    }

    // MARK: - Commands

    /// Loads the configuration, sets up the alerts, reads the permissions and the installed models, and starts
    /// listening if setup is done and the user wants it at launch. Later calls do nothing.
    public func bootstrap() async {
        await command {
            guard !isBootstrapped else { return }
            isBootstrapped = true
            await loadConfigurationIfNeeded()
            permissions = await dependencies.permissions.snapshot()
            await refreshInstalledModels()
            if configuration.history.isEnabled {
                recentHits = Array(await dependencies.historyStore.load().prefix(Self.recentHitLimit))
            }
            _ = await resolve()
            if configuration.hasCompletedOnboarding, configuration.listening.startOnLaunch {
                await performStart()
            }
        }
    }

    /// Starts listening, unless it is under way already. From an error, it tries again at once.
    public func start() async {
        await command { await performStart() }
    }

    /// Stops everything: `.off`.
    public func pause() async {
        await command { await performPause() }
    }

    /// Pauses when listening, getting ready, waiting for a call or snoozed; starts otherwise.
    public func toggle() async {
        await command {
            switch state {
            case .listening, .preparing, .waitingForCall, .snoozed: await performPause()
            case .off, .error: await performStart()
            }
        }
    }

    /// Stops everything and starts listening again after `minutes` (at least 1, at most a week), unless another command
    /// comes first.
    public func snooze(minutes: Int) async {
        await command { await performSnooze(minutes: minutes) }
    }

    /// Ends a snooze now: the same as `start()`.
    public func resume() async {
        await command { await performStart() }
    }

    /// Changes the configuration and saves it. A change to the audio source, the mode, the engine, the model size or
    /// the language restarts listening if it is on (or failed); a change to the rules reaches the running engine's
    /// hints without a restart; a change to the channels or the global cooldown reaches the alerts.
    public func update(_ mutate: (inout AppConfiguration) -> Void) async {
        await command {
            await loadConfigurationIfNeeded()
            let old = configuration
            var new = old
            mutate(&new)
            guard new != old else { return }
            configuration = new
            await dependencies.configStore.save(new)
            await apply(new, replacing: old)
        }
    }

    /// Marks setup as done, turns "Start listening when the app opens" on (setting up later turned it off, and finishing
    /// setup now means listening), saves that, and starts listening.
    public func completeOnboarding() async {
        await command {
            await loadConfigurationIfNeeded()
            if !configuration.hasCompletedOnboarding || !configuration.listening.startOnLaunch {
                configuration.hasCompletedOnboarding = true
                configuration.listening.startOnLaunch = true
                await dependencies.configStore.save(configuration)
            }
            await performStart()
        }
    }

    /// Writes the configuration and the history that are waiting, then stops listening for the Mac's sleep,
    /// remembering to start again after it wakes. Also the thing to call when the app quits.
    ///
    /// The writing comes first, so that a capture source or an engine that hangs while stopping cannot keep them from
    /// the disk. A hit heard while listening stops is written after that.
    public func systemWillSleep() async {
        await command {
            await flushStores()
            if let current = session, current.isRunning, current.kind != .snoozeTimer {
                resumesAfterWake = true
                await endSession()
                showStopped(.off)
                logger.info("Stopped listening for sleep")
                await flushStores()
            }
        }
    }

    /// Starts listening 2 s after waking, if sleep stopped it.
    public func systemDidWake() async {
        await command {
            guard resumesAfterWake else { return }
            resumesAfterWake = false
            await endSession()
            beginSession(.wakeTimer) { id in
                do { try await self.dependencies.sleep(Self.wakeDelay) } catch { return }
                guard !Task.isCancelled else { return }
                self.startAsCommand(unlessReplaced: id)
            }
        }
    }

    // MARK: - Other requests

    /// Sends a sample hit to one channel, whatever the rules and cooldowns say. Throws what the delivery threw.
    public func testAlert(_ kind: ChannelKind) async throws {
        let rule = configuration.rules.first
        let term =
            rule?.terms.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? AppName.current
        let hit = Hit(
            ruleID: rule?.id ?? Self.testRuleID, ruleName: "Test", term: term, matchedText: term,
            context: "This is a test alert from \(AppName.current).", timestamp: dependencies.now(),
            source: configuration.listening.source, engine: activeEngine ?? .appleSFSpeech, segmentID: "test")
        try await dispatcher.test(kind, hit: hit)
    }

    public func lastDeliveryFailures() async -> [ChannelKind: DeliveryFailure] {
        await dispatcher.lastFailures()
    }

    /// Reads the permissions again. When listening stopped for a permission that is now granted, it starts again.
    public func refreshPermissions() async {
        permissions = await dependencies.permissions.snapshot()
        guard case .error(.permissionDenied(let kind)) = state, permissions[kind] == .granted else { return }
        // ScreenCaptureKit only sees a new grant after a relaunch; trying again would only fail again.
        if kind == .screenRecording, warnings.contains(.screenRecordingNeedsRelaunch) { return }
        await command {
            guard case .error(.permissionDenied(kind)) = state else { return }  // a command changed things meanwhile
            await performStart()
        }
    }

    /// Asks for a permission (the system prompt shows if the user has not decided yet), then reads them all again.
    public func requestPermission(_ kind: PermissionKind) async -> Bool {
        let granted = await dependencies.permissions.request(kind)
        await refreshPermissions()
        return granted
    }

    /// The permissions listening needs with the current settings: the capture ones for the audio source, and speech
    /// recognition when the engine is Apple's `SFSpeechRecognizer` (as of the latest engine pick, see `resolvedEngine()`).
    public func requiredPermissions() -> [PermissionKind] {
        var kinds = Self.capturePermissions(for: configuration.listening.source)
        if case .engine(.appleSFSpeech, _) = lastResolution { kinds.append(.speechRecognition) }
        return kinds
    }

    /// The engine the current settings pick on this Mac.
    public func resolvedEngine() async -> EngineResolution {
        await resolve()
    }

    /// Downloads a model, and the speech detector with the first whisper model.
    public func downloadModel(_ model: WhisperModel) async throws {
        try await download(model)
        if model != .vad, !(await dependencies.models.isInstalled(.vad)) {
            try await download(.vad)
        }
    }

    /// Deletes a model. A download of it that is running stops. Throws `ListeningControllerError.modelInUse` for a model
    /// the running engine uses.
    public func deleteModel(_ model: WhisperModel) async throws {
        guard !modelsInUse.contains(model) else { throw ListeningControllerError.modelInUse }
        do {
            try await dependencies.models.delete(model)
        } catch {
            if !(await dependencies.models.isInstalled(model)) { installedModels.remove(model) }
            throw error
        }
        installedModels.remove(model)
    }

    /// The history, newest first.
    public func history() async -> [Hit] {
        await dependencies.historyStore.all()
    }

    /// Deletes the history, and forgets the recent hits.
    public func clearHistory() async {
        await dependencies.historyStore.clear()
        recentHits = []
    }

    // MARK: - Commands, one at a time

    private func command(_ body: () async -> Void) async {
        await commands.enter()
        defer { commands.leave() }
        await body()
    }

    /// Starts a listening session, unless listening is under way.
    private func performStart() async {
        resumesAfterWake = false
        await loadConfigurationIfNeeded()
        switch state {
        case .preparing, .listening, .waitingForCall: return
        case .off, .snoozed, .error: await restart()
        }
    }

    private func performPause() async {
        resumesAfterWake = false
        await endSession()
        showStopped(.off)
    }

    private func performSnooze(minutes: Int) async {
        resumesAfterWake = false
        await endSession()
        let minutes = min(max(minutes, 1), Self.longestSnoozeMinutes)
        let seconds = minutes * 60
        showStopped(.snoozed(until: dependencies.now().addingTimeInterval(TimeInterval(seconds))))
        logger.info("Snoozed for \(minutes, privacy: .public) min")
        beginSession(.snoozeTimer) { id in
            do { try await self.dependencies.sleep(.seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            self.startAsCommand(unlessReplaced: id)
        }
    }

    /// Ends the session, whatever it is, and starts listening.
    private func restart() async {
        await endSession()
        state = .preparing(.permissions)
        beginSession(.listening) { _ in await self.listen() }
    }

    /// Starts listening in a command of its own, if session `id` is still the latest by then. The timers use it: a
    /// command ends their session and waits for it, so they must not wait for a command themselves.
    private func startAsCommand(unlessReplaced id: UInt64) {
        Task {
            await self.command {
                guard self.session?.id == id else { return }
                await self.performStart()
            }
        }
    }

    private func apply(_ new: AppConfiguration, replacing old: AppConfiguration) async {
        if new.rules != old.rules {
            ruleEngine.updateRules(new.rules)
            if let engine = currentEngine { await engine.updateHints(RuleEngine.hints(for: new.rules)) }
        }
        if new.channels != old.channels || new.globalCooldownSeconds != old.globalCooldownSeconds {
            await dispatcher.configure(settings: new.channels, globalCooldownSeconds: new.globalCooldownSeconds)
        }
        if new.speech.engine != old.speech.engine || new.speech.localModelSize != old.speech.localModelSize {
            clearFallingBehind()
        }
        if new.speech != old.speech { _ = await resolve() }
        let listeningChanged =
            new.listening.source != old.listening.source || new.listening.mode != old.listening.mode
            || new.speech != old.speech
        guard listeningChanged else { return }
        switch state {
        case .preparing, .listening, .waitingForCall, .error:
            resumesAfterWake = false
            await restart()
        case .off, .snoozed:
            break  // used the next time listening starts
        }
    }

    private func flushStores() async {
        await dependencies.configStore.flush()
        await dependencies.historyStore.flush()
    }

    private func loadConfigurationIfNeeded() async {
        guard !isConfigurationLoaded else { return }
        isConfigurationLoaded = true
        let loaded = await dependencies.configStore.load()
        configuration = loaded
        ruleEngine.updateRules(loaded.rules)
        await dispatcher.configure(settings: loaded.channels, globalCooldownSeconds: loaded.globalCooldownSeconds)
    }

    private func refreshInstalledModels() async {
        var installed: Set<WhisperModel> = []
        for model in WhisperModel.allCases {
            if await dependencies.models.isInstalled(model) { installed.insert(model) }
        }
        installedModels = installed
    }

    /// Shows a state with nothing running behind it: no level, no engine, and nothing heard kept.
    private func showStopped(_ newState: ListeningState) {
        state = newState
        level = 0
        activeEngine = nil
        memory = TranscriptMemory()
        liveTranscript = ""
    }

    /// Shows `newState`, unless the current task was cancelled: a command has taken over then, and shows its own.
    private func setState(_ newState: ListeningState) {
        guard !Task.isCancelled else { return }
        state = newState
    }

    // MARK: - Sessions

    private func beginSession(_ kind: Session.Kind, _ work: @escaping @MainActor (UInt64) async -> Void) {
        sessionCount += 1
        let current = Session(id: sessionCount, kind: kind)
        session = current
        current.task = Task {
            await work(current.id)
            current.isRunning = false
        }
    }

    /// Cancels the session and waits until everything it started has stopped.
    private func endSession() async {
        guard let current = session else { return }
        session = nil
        current.task?.cancel()
        await current.task?.value
        current.isRunning = false
    }

    /// A listening session: listens until a command ends it, or until something only the user can fix.
    private func listen() async {
        let end: AttemptEnd
        if configuration.listening.mode == .duringCalls, dependencies.callDetectionSupported {
            end = await listenDuringCalls()
        } else {
            if configuration.listening.mode == .duringCalls {
                logger.info("Calls cannot be detected on this Mac, so listening goes on all the time")
            }
            end = await keepListening()
        }
        guard !Task.isCancelled else { return }
        switch end {
        case .cancelled, .transient:
            return  // a transient failure never ends a session
        case .stoppedByUser:
            logger.info("Capture was stopped from the system's recording indicator: listening is paused")
            showStopped(.off)
        case .permanent(let issue):
            logger.error("Not listening: \(String(describing: issue), privacy: .public)")
            showStopped(.error(issue))
        }
    }

    /// Makes attempts one after another until one ends for good. After a failure it waits `backoffBase × 2ⁿ` (n
    /// failures in a row before this one, up to 30 × `backoffBase`); an attempt that listened for a minute starts n
    /// at 0 again.
    private func keepListening() async -> AttemptEnd {
        var failures = 0
        while true {
            let attempt = await runAttempt()
            guard !Task.isCancelled else { return .cancelled }
            guard case .transient(let issue) = attempt.end else { return attempt.end }
            if let since = attempt.listeningSince,
                dependencies.now().timeIntervalSince(since) >= Self.healthyListeningSeconds
            {
                failures = 0
            }
            let delay = backoff(afterFailures: failures)
            failures += 1
            logger.error("""
                Listening failed (\(String(describing: issue), privacy: .public)); \
                trying again in \(String(describing: delay), privacy: .public)
                """)
            setState(.error(issue))
            do { try await dependencies.sleep(delay) } catch { return .cancelled }
            guard !Task.isCancelled else { return .cancelled }
        }
    }

    private func backoff(afterFailures failures: Int) -> Duration {
        let base = dependencies.backoffBase
        let longest = base * Self.backoffCapFactor
        guard failures < 5 else { return longest }  // 2⁵ is past the cap already
        return min(base * (1 << failures), longest)
    }

    /// "Only during calls": gets ready, then waits for calls, and makes attempts while one lasts. One subscription to
    /// the call state serves the whole session, because a new one would start the detector's browser delay again.
    private func listenDuringCalls() async -> AttemptEnd {
        setState(.preparing(.permissions))
        switch await makePlan() {
        case .ended(let end):
            return end
        case .ready(let plan):
            // Download now rather than when the call starts.
            if let end = await installModels(for: plan) { return end }
        }
        guard !Task.isCancelled else { return .cancelled }
        setState(.waitingForCall)
        logger.info("Waiting for a call")

        let (events, post) = AsyncStream.makeStream(of: CallEvent.self)
        let subscribe = dependencies.callStates
        let watcher = Task {
            for await callState in subscribe() { post.yield(.call(callState)) }
            post.yield(.callsEnded)
        }
        var call: (id: Int, attempts: Task<Void, Never>)?
        var callCount = 0
        var outcome = AttemptEnd.cancelled
        events: for await event in events {
            switch event {
            case .call(.active):
                guard call == nil, !Task.isCancelled else { continue }
                callCount += 1
                let id = callCount
                logger.info("A call started")
                call = (id, Task { post.yield(.attemptsEnded(id: id, await self.keepListening())) })
            case .call(.inactive):
                guard let current = call else { continue }
                call = nil
                logger.info("The call ended")
                current.attempts.cancel()
                await current.attempts.value
                if !Task.isCancelled {
                    level = 0
                    memory.dropPending()
                    liveTranscript = memory.live
                    state = .waitingForCall
                }
            case .attemptsEnded(let id, let end):
                guard id == call?.id else { continue }  // a call that has ended already
                call = nil
                if case .cancelled = end { continue }
                outcome = end
                break events
            case .callsEnded:
                logger.error("Call detection stopped; staying as it is")
            }
        }
        watcher.cancel()
        if let current = call {
            current.attempts.cancel()
            await current.attempts.value
        }
        post.finish()
        return Task.isCancelled ? .cancelled : outcome
    }

    // MARK: - One attempt

    /// One attempt to listen: check the permissions and pick the engine, download what is missing, get a new engine
    /// ready, start a new capture source, and run the pipeline until it ends. Whatever was started is stopped before
    /// this returns.
    private func runAttempt() async -> AttemptOutcome {
        setState(.preparing(.permissions))
        let plan: ListeningPlan
        switch await makePlan() {
        case .ended(let end): return AttemptOutcome(end: end)
        case .ready(let ready): plan = ready
        }
        if let end = await installModels(for: plan) { return AttemptOutcome(end: end) }
        guard !Task.isCancelled else { return AttemptOutcome(end: .cancelled) }

        setState(.preparing(.starting))
        modelsInUse = Set(plan.models)
        defer { modelsInUse = [] }
        let engine = dependencies.makeEngine(plan.engine)
        currentEngine = engine
        defer { currentEngine = nil }
        if let end = await prepare(engine, for: plan) { return AttemptOutcome(end: end) }

        let source = dependencies.makeSource(plan.source)
        let chunks: AsyncStream<AudioChunk>
        switch await startCapture(source) {
        case nil:
            await stopEngine(engine)
            guard !Task.isCancelled else { return AttemptOutcome(end: .cancelled) }
            logger.error("Audio capture did not start in time; the next attempt uses a new capture source")
            return AttemptOutcome(end: .transient(.captureFailed(Self.unresponsiveCapture)))
        case .failure(let error)?:
            await stopEngine(engine)
            guard !Task.isCancelled else { return AttemptOutcome(end: .cancelled) }
            return AttemptOutcome(end: startFailure(error, source: plan.source))
        case .success(let stream)?:
            chunks = stream
        }
        guard !Task.isCancelled else {
            await stopCapture(source)
            await stopEngine(engine)
            return AttemptOutcome(end: .cancelled)
        }

        ruleEngine.forgetSegments()  // the new engine numbers its segments from the start again
        clearFallingBehind()  // a new engine has no backlog; it warns again if it falls behind too
        let info = ListeningInfo(engine: engine.id, source: plan.source, localeIdentifier: plan.localeIdentifier)
        let outcome = await runPipeline(chunks: chunks, source: source, engine: engine, info: info)
        await stopCapture(source)
        await stopEngine(engine)
        if !Task.isCancelled {
            level = 0
            memory.dropPending()
            liveTranscript = memory.live
        }
        return outcome
    }

    /// Checks the permissions and picks the engine. The permissions for the audio source come first; speech
    /// recognition is needed only by `SFSpeechRecognizer` (the SpeechAnalyzer engines work without it).
    private func makePlan() async -> PlanOutcome {
        let snapshot = await dependencies.permissions.snapshot()
        guard !Task.isCancelled else { return .ended(.cancelled) }
        if permissions != snapshot { permissions = snapshot }  // retries must not wake the UI for nothing
        let source = configuration.listening.source
        if let missing = Self.capturePermissions(for: source).first(where: { snapshot[$0] != .granted }) {
            return .ended(.permanent(.permissionDenied(missing)))
        }
        let resolution = await resolve()
        guard !Task.isCancelled else { return .ended(.cancelled) }
        switch resolution {
        case .unavailable(let reason):
            return .ended(.permanent(.engineUnavailable(reason)))
        case .engine(let engine, let locale):
            if engine == .appleSFSpeech, snapshot.speechRecognition != .granted {
                return .ended(.permanent(.permissionDenied(.speechRecognition)))
            }
            if activeEngine != engine { activeEngine = engine }
            return .ready(ListeningPlan(engine: engine, localeIdentifier: locale, source: source))
        }
    }

    private func resolve() async -> EngineResolution {
        let capabilities = await dependencies.capabilities()
        let speech = configuration.speech
        let locale = speech.localeIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? dependencies.systemLocaleIdentifier()
        let resolution = EngineResolver.resolve(
            preference: speech.engine, localeIdentifier: locale, localModelSize: speech.localModelSize,
            capabilities: capabilities)
        lastResolution = resolution
        return resolution
    }

    /// Downloads the models the plan needs that are not on disk, showing their progress as one. A download that fails,
    /// or stops because the model was deleted meanwhile, ends the session with `.modelMissing`.
    private func installModels(for plan: ListeningPlan) async -> AttemptEnd? {
        var missing: [WhisperModel] = []
        for model in plan.models {
            if !(await dependencies.models.isInstalled(model)) { missing.append(model) }
        }
        guard !Task.isCancelled else { return .cancelled }
        guard !missing.isEmpty else { return nil }

        let phase = beginProgressPhase()
        defer { endProgressPhase(phase) }
        let sizes = missing.map { Double(max(ModelCatalog.descriptor($0).bytes, 1)) }
        let total = sizes.reduce(0, +)
        var done = 0.0
        setState(.preparing(.downloadingModel(0)))
        for (model, size) in zip(missing, sizes) {
            let before = done
            do {
                try await download(model) { fraction in
                    self.showProgress(.downloadingModel((before + fraction * size) / total), phase: phase)
                }
            } catch {
                guard !Task.isCancelled else { return .cancelled }
                if error is CancellationError {
                    logger.error("The download of \(model.rawValue, privacy: .public) stopped: the model was deleted")
                } else {
                    logger.error("""
                        Could not download \(model.rawValue, privacy: .public): \
                        \(error.localizedDescription, privacy: .public)
                        """)
                }
                return .permanent(.modelMissing)
            }
            done += size
        }
        return nil
    }

    /// Downloads a model through `dependencies.models`, keeping `modelDownloads` and `installedModels` up to date.
    /// `progress` hears the fraction on the main actor.
    private func download(
        _ model: WhisperModel, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        downloadCounts[model, default: 0] += 1
        if modelDownloads[model] == nil { modelDownloads[model] = 0 }
        defer {
            let remaining = (downloadCounts[model] ?? 1) - 1
            if remaining > 0 {
                downloadCounts[model] = remaining
            } else {
                downloadCounts[model] = nil
                modelDownloads[model] = nil
            }
        }
        try await dependencies.models.download(model) { fraction in
            Task { @MainActor in
                guard self.downloadCounts[model] != nil else { return }  // late: the download is over
                self.modelDownloads[model] = fraction
                progress(fraction)
            }
        }
        installedModels.insert(model)
    }

    /// Gets the engine ready for the plan's language, showing Apple's asset installation. Returns how the attempt
    /// ends when it could not, after stopping the engine. A command that comes meanwhile does not wait for this: the
    /// preparation is cancelled and left to finish by itself, and the engine is stopped once it has.
    private func prepare(_ engine: any SpeechEngine, for plan: ListeningPlan) async -> AttemptEnd? {
        let phase = beginProgressPhase()
        defer { endProgressPhase(phase) }
        let hints = RuleEngine.hints(for: configuration.rules)
        let locale = plan.localeIdentifier
        let report: @Sendable (PreparationProgress) -> Void = { progress in
            Task { @MainActor in
                let fraction = min(max(progress.fraction, 0), 1)
                switch progress.stage {
                case .downloadingModel: self.showProgress(.downloadingModel(fraction), phase: phase)
                case .installingAppleAssets: self.showProgress(.installingAppleAssets(fraction), phase: phase)
                }
            }
        }
        let result = await Abandonable.run {
            try await engine.prepare(localeIdentifier: locale, hints: hints, progress: report)
        } afterwards: {
            await engine.stop()
        }
        guard let result else { return .cancelled }
        switch result {
        case .success:
            guard !Task.isCancelled else {
                await stopEngine(engine)
                return .cancelled
            }
            return nil
        case .failure(let error):
            await stopEngine(engine)
            guard !Task.isCancelled else { return .cancelled }
            let end = Self.speechFailure(error)
            logger.error("The speech engine could not get ready: \(String(describing: end), privacy: .public)")
            return end
        }
    }

    private func beginProgressPhase() -> UInt64 {
        progressPhases += 1
        shownProgressPhase = progressPhases
        return progressPhases
    }

    private func endProgressPhase(_ phase: UInt64) {
        if shownProgressPhase == phase { shownProgressPhase = nil }
    }

    private func showProgress(_ stage: PreparationStage, phase: UInt64) {
        guard shownProgressPhase == phase, case .preparing = state else { return }
        state = .preparing(stage)
    }

    /// Starts capture, waiting at most `captureCallLimit`. Nil when the source did not answer in time; it is left
    /// behind then, and stopped if it starts after all.
    private func startCapture(_ source: any AudioCaptureSource) async -> Result<AsyncStream<AudioChunk>, any Error>? {
        await TimeLimit.run(captureCallLimit) {
            do {
                return .success(try await source.start())
            } catch {
                return .failure(error)
            }
        } late: { result in
            if case .success = result { await source.stop() }
        }
    }

    private func stopCapture(_ source: any AudioCaptureSource) async {
        if await TimeLimit.run(captureCallLimit, { await source.stop() }) == nil {
            logger.error("Audio capture did not stop in time; it was left behind")
        }
    }

    private func stopEngine(_ engine: any SpeechEngine) async {
        if await TimeLimit.run(captureCallLimit, { await engine.stop() }) == nil {
            logger.error("The speech engine did not stop in time; it was left behind")
        }
    }

    // MARK: - The pipeline

    /// Feeds the audio to the engine and the engine's text to the rules until the audio ends, the engine stops, or the
    /// attempt is cancelled. The audio's reason for ending wins when both end.
    ///
    /// When the audio ends by itself, the engine still has the last words to finish: its text is read on until it
    /// ends, for at most `transcriptDrainLimit`, so that a final result that comes just after the audio still counts.
    private func runPipeline(
        chunks: AsyncStream<AudioChunk>, source: any AudioCaptureSource, engine: any SpeechEngine, info: ListeningInfo
    ) async -> AttemptOutcome {
        let (input, feed) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(Self.bufferedChunks))
        let updates = engine.transcribe(input)
        let run = PipelineRun()
        let limit = captureCallLimit
        let drainLimit = transcriptDrainLimit
        let end = await withTaskGroup(of: PipelineEvent?.self, returning: AttemptEnd.self) { group in
            // Both parts run on the main actor (their methods are isolated to it), as children of this group: cancelling
            // the attempt cancels them, and the group waits for them before it returns.
            group.addTask {
                await self.relayAudio(chunks, to: feed, from: source, run: run, info: info, limit: limit)
            }
            group.addTask {
                await self.readTranscript(updates, info: info)
            }
            // How the attempt ends, once the audio has said why it ended.
            var audioEnd: AttemptEnd?
            // The engine's text ended after the audio did: nothing more is coming.
            var transcriptEnded = false
            while let event = await group.next() {
                switch event {
                case .audioEnded(let reason)?:
                    let end = Self.audioEnd(reason)
                    if transcriptEnded {
                        group.cancelAll()
                        return end
                    }
                    audioEnd = end
                    group.addTask {
                        do { try await Task.sleep(for: drainLimit) } catch { return nil }
                        return .drainTimeUp
                    }
                case .engineEnded(let error)?:
                    if run.audioEnded {
                        // The engine only followed the audio, whose reason says why.
                        transcriptEnded = true
                        guard let audioEnd else { continue }
                        group.cancelAll()
                        return audioEnd
                    }
                    group.cancelAll()
                    return error.map(Self.speechFailure) ?? .transient(.engineFailed(Self.stoppedRecognition))
                case .drainTimeUp?:
                    logger.notice("The speech engine was still busy after the audio ended; its last words were dropped")
                    group.cancelAll()
                    return audioEnd ?? .cancelled
                case nil:
                    continue  // a part that was cancelled
                }
            }
            return audioEnd ?? .cancelled
        }
        return AttemptOutcome(end: end, listeningSince: run.listeningSince)
    }

    /// Passes the audio on to the engine until it stops coming, then finishes the engine's input and says why the
    /// audio ended. Nil when cancelled.
    private func relayAudio(
        _ chunks: AsyncStream<AudioChunk>, to feed: AsyncStream<AudioChunk>.Continuation,
        from source: any AudioCaptureSource, run: PipelineRun, info: ListeningInfo, limit: Duration
    ) async -> PipelineEvent? {
        for await chunk in chunks {
            if Task.isCancelled { break }
            took(chunk, run: run, info: info)
            feed.yield(chunk)
        }
        run.audioEnded = true
        feed.finish()
        if Task.isCancelled { return nil }
        let reason = await TimeLimit.run(limit) { await source.endReason() }
        return .audioEnded(reason ?? nil)
    }

    /// Reads what the engine hears until it stops. Nil when cancelled.
    private func readTranscript(
        _ updates: AsyncThrowingStream<TranscriptUpdate, any Error>, info: ListeningInfo
    ) async -> PipelineEvent? {
        do {
            for try await update in updates {
                if Task.isCancelled { break }
                await heard(update, info: info)
            }
            return Task.isCancelled ? nil : .engineEnded(nil)
        } catch {
            return Task.isCancelled ? nil : .engineEnded(error)
        }
    }

    /// A chunk of audio arrived: the first one means listening has begun.
    private func took(_ chunk: AudioChunk, run: PipelineRun, info: ListeningInfo) {
        let now = dependencies.now()
        if run.listeningSince == nil {
            run.listeningSince = now
            activeEngine = info.engine
            state = .listening(info)
            logger.info("""
                Listening to \(info.source.rawValue, privacy: .public) with \(info.engine.rawValue, privacy: .public) \
                (\(info.localeIdentifier, privacy: .public))
                """)
        }
        if let shown = run.levelShownAt, now >= shown, now.timeIntervalSince(shown) < Self.levelInterval { return }
        run.levelShownAt = now
        level = Self.level(rms: chunk.rms)
    }

    /// What the meter shows for audio this loud, from 0 to 1 on a decibel scale, the way ears hear it: −60 dBFS and
    /// quieter show 0, full scale (0 dBFS) shows 1, and each 6 dB in between moves it a tenth.
    nonisolated static func level(rms: Float) -> Double {
        let decibels = 20 * log10(Double(rms) + 1e-9)
        let level = (decibels + 60) / 60
        return level.isNaN ? 0 : min(max(level, 0), 1)
    }

    /// The engine heard something: show the text, check the rules, and send the hits on.
    private func heard(_ update: TranscriptUpdate, info: ListeningInfo) async {
        let now = dependencies.now()
        let hits = ruleEngine.evaluate(update, source: info.source, engine: info.engine, now: now)
        // The excerpt ends with this update's text, so it is made before the update joins what was heard.
        let excerpt = hits.isEmpty ? nil : memory.excerpt(endingWith: update.text, at: now)
        memory.take(update, at: now)
        liveTranscript = memory.live
        for var hit in hits {
            hit.excerpt = excerpt
            await send(hit)
        }
    }

    /// Hands a hit to the alerts. Unless the global cooldown holds it back, it is recorded at once (the recent hits,
    /// when the last hit was heard, the history) and its deliveries start in a task of their own. Neither the pipeline
    /// nor a pause waits for or stops the deliveries: the hit was heard before that.
    private func send(_ hit: Hit) async {
        guard let rule = configuration.rules.first(where: { $0.id == hit.ruleID }) else { return }
        guard await dispatcher.admit(hit, rule: rule) else { return }  // held back by the global cooldown
        // Admitted: from here on, it is recorded and delivered exactly once, whatever happens meanwhile.
        await record(hit)
        startDeliveries(of: hit, rule: rule)
    }

    private func startDeliveries(of hit: Hit, rule: Rule) {
        deliveryCount &+= 1
        let id = deliveryCount
        let dispatcher = dispatcher
        // The task cannot run before it is stored: both happen on the main actor, and this does not suspend.
        deliveries[id] = Task {
            await dispatcher.deliver(hit, rule: rule)
            self.deliveries[id] = nil
        }
    }

    /// How many hits are still being delivered. For tests.
    var deliveriesUnderWay: Int { deliveries.count }

    private func record(_ hit: Hit) async {
        let index = recentHits.firstIndex { $0.timestamp < hit.timestamp } ?? recentHits.endIndex
        if index < Self.recentHitLimit {
            recentHits.insert(hit, at: index)
            if recentHits.count > Self.recentHitLimit { recentHits.removeLast(recentHits.count - Self.recentHitLimit) }
        }
        if lastHitAt.map({ hit.timestamp > $0 }) ?? true { lastHitAt = hit.timestamp }
        if configuration.history.isEnabled { await dependencies.historyStore.append(hit) }
    }

    // MARK: - Warnings and previews

    /// The local model cannot keep up with the audio. The whisper engines report it through `ControllerBox`.
    ///
    /// The warning lasts until listening starts over with a new pipeline, or until two minutes pass without another
    /// report: each report starts those two minutes again.
    func noteLocalModelFallingBehind() {
        fallingBehindExpiry?.cancel()
        let sleep = dependencies.sleep
        fallingBehindExpiry = Task {
            do { try await sleep(Self.fallingBehindQuietPeriod) } catch { return }
            // Checked on the main actor, where a newer report cancels this one before starting its own.
            guard !Task.isCancelled else { return }
            self.clearFallingBehind()
        }
        guard warnings.insert(.localModelFallingBehind).inserted else { return }
        logger.info("The local model is falling behind the audio")
    }

    private func clearFallingBehind() {
        fallingBehindExpiry?.cancel()
        fallingBehindExpiry = nil
        warnings.remove(.localModelFallingBehind)
    }

    /// Shows the given state as it is, with nothing running behind it, for previews and screenshots (`demo`).
    func present(
        configuration: AppConfiguration, state: ListeningState, recentHits: [Hit], liveTranscript: String, level: Double
    ) {
        isConfigurationLoaded = true
        isBootstrapped = true
        self.configuration = configuration
        ruleEngine.updateRules(configuration.rules)
        self.state = state
        self.recentHits = recentHits
        self.liveTranscript = liveTranscript
        self.level = level
        permissions = PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .granted)
        if case .listening(let info) = state { activeEngine = info.engine }
    }

    // MARK: - Classifying what went wrong

    private static func capturePermissions(for source: AudioSourceKind) -> [PermissionKind] {
        switch source {
        case .systemAudio: [.screenRecording]
        case .microphone: [.microphone]
        case .both: [.microphone, .screenRecording]
        }
    }

    private func startFailure(_ error: any Error, source: AudioSourceKind) -> AttemptEnd {
        guard let error = error as? AudioCaptureError else {
            logger.error("Audio capture could not start: \(error.localizedDescription, privacy: .public)")
            return .transient(.captureFailed(error is CancellationError ? Self.stoppedCapture : error.localizedDescription))
        }
        switch error {
        case .permissionDenied:
            let kind: PermissionKind = source == .microphone ? .microphone : .screenRecording
            if kind == .screenRecording, permissions.screenRecording == .granted {
                warnings.insert(.screenRecordingNeedsRelaunch)
                logger.error("Screen recording is allowed, but capture was refused: NameAlert must relaunch")
            }
            return .permanent(.permissionDenied(kind))
        case .noInputDevice:
            return .transient(.captureFailed("No microphone is connected."))
        case .noDisplay:
            return .transient(.captureFailed("No display is available to capture system audio from."))
        case .startFailed(let message):
            return .transient(.captureFailed(message))
        }
    }

    private static func audioEnd(_ reason: CaptureEndReason?) -> AttemptEnd {
        switch reason {
        case .stoppedByUser: .stoppedByUser
        case .failed(let message): .transient(.captureFailed(message))
        case .stopped, nil: .transient(.captureFailed(stoppedCapture))
        }
    }

    /// What an engine's error means, whether it came while getting ready or while listening.
    private static func speechFailure(_ error: any Error) -> AttemptEnd {
        guard let error = error as? SpeechEngineError else {
            if error is CancellationError { return .transient(.engineFailed(stoppedRecognition)) }
            return .transient(.engineFailed(error.localizedDescription))
        }
        switch error {
        case .unsupportedLocale(let identifier):
            return .permanent(.engineUnavailable("Speech recognition isn't available for \(identifier) on this Mac."))
        case .modelNotInstalled:
            return .permanent(.modelMissing)
        case .permissionDenied:
            return .permanent(.permissionDenied(.speechRecognition))
        case .assetsUnavailable:
            return .transient(.engineFailed("Apple's speech files for this language couldn't be installed."))
        case .engineFailed(let message):
            return .transient(.engineFailed(message))
        }
    }

    // MARK: - Constants

    static let recentHitLimit = 5
    /// 15 level updates a second at most.
    static let levelInterval: TimeInterval = 1.0 / 15
    /// Listening this long before a failure starts the backoff from the beginning.
    static let healthyListeningSeconds: TimeInterval = 60
    /// The longest backoff, in multiples of `backoffBase`.
    static let backoffCapFactor = 30
    static let wakeDelay: Duration = .seconds(2)
    /// How long the local model must keep up before its falling-behind warning goes away by itself.
    static let fallingBehindQuietPeriod: Duration = .seconds(120)
    static let longestSnoozeMinutes = 7 * 24 * 60
    /// About 5 s of audio waits for an engine that falls behind; older chunks are dropped.
    static let bufferedChunks = 50
    /// The rule ID of a test alert when there is no rule ("NAMEALERTTEST").
    static let testRuleID = UUID(uuid: (0x4E, 0x41, 0x4D, 0x45, 0x41, 0x4C, 0x45, 0x52, 0x54, 0x54, 0x45, 0x53, 0x54, 0, 0, 0))
    static let stoppedCapture = "Audio capture stopped unexpectedly."
    static let unresponsiveCapture = "Audio capture didn't respond."
    static let stoppedRecognition = "Speech recognition stopped unexpectedly."
}

// MARK: - Supporting types

/// Lets commands run one at a time, in the order they arrive.
@MainActor
private final class CommandQueue {
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Returns when it is the caller's turn. The caller has its place before this first suspends.
    func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the command that has waited longest.
    func leave() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Long-running work a command started: listening, or a timer that starts it later.
@MainActor
private final class Session {
    enum Kind { case listening, snoozeTimer, wakeTimer }

    let id: UInt64
    let kind: Kind
    var task: Task<Void, Never>?
    /// False once the work is over, by itself or after being cancelled.
    var isRunning = true

    init(id: UInt64, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// How an attempt to listen ended.
private enum AttemptEnd: Sendable {
    /// A command ended it.
    case cancelled
    /// Capture or the engine failed: try again after a pause.
    case transient(ListeningIssue)
    /// Only the user can fix it: show it and stop.
    case permanent(ListeningIssue)
    /// The user stopped capture from the system's recording indicator, which counts as a pause.
    case stoppedByUser
}

private struct AttemptOutcome {
    var end: AttemptEnd
    /// When the attempt began to listen, if it did.
    var listeningSince: Date?
}

private enum PlanOutcome {
    case ready(ListeningPlan)
    case ended(AttemptEnd)
}

/// What an attempt listens with.
private struct ListeningPlan {
    let engine: EngineID
    /// Spelled the way the engine lists it.
    let localeIdentifier: String
    let source: AudioSourceKind

    /// The model files the engine needs: a whisper model and the speech detector, or nothing for Apple's engines.
    var models: [WhisperModel] {
        switch engine {
        case .whisperLight: [ModelCatalog.model(size: .light, localeIdentifier: localeIdentifier), .vad]
        case .whisperBalanced: [ModelCatalog.model(size: .balanced, localeIdentifier: localeIdentifier), .vad]
        case .appleSpeechTranscriber, .appleDictationTranscriber, .appleSFSpeech: []
        }
    }
}

/// What one run of the pipeline has seen.
@MainActor
private final class PipelineRun {
    /// The audio stopped coming (or its reading was cancelled), so the engine's input is finished.
    var audioEnded = false
    var listeningSince: Date?
    var levelShownAt: Date?
}

private enum PipelineEvent: Sendable {
    case audioEnded(CaptureEndReason?)
    case engineEnded((any Error)?)
    /// The engine had `transcriptDrainLimit` to finish after the audio ended, and did not.
    case drainTimeUp
}

private enum CallEvent: Sendable {
    case call(CallState)
    case callsEnded
    case attemptsEnded(id: Int, AttemptEnd)
}

/// What was heard lately: the live transcript, and the final texts of the last half minute for hit excerpts.
struct TranscriptMemory {
    static let liveLimit = 300
    static let excerptLimit = 600
    static let excerptWindow: TimeInterval = 30
    /// The most final text kept for excerpts, so that a long stretch of speech cannot make it grow without end.
    private static let keptLimit = 4 * excerptLimit

    /// The last `liveLimit` characters: the final text, then the text of the segment still being recognized.
    private(set) var live = ""
    private var spoken = ""
    private var pending: (segmentID: String, text: String)?
    private var finals: [(date: Date, text: String)] = []

    /// Takes in an update: a final one joins the text for good, a volatile one stands for its segment until replaced.
    mutating func take(_ update: TranscriptUpdate, at now: Date) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if update.isFinal {
            if pending?.segmentID == update.segmentID { pending = nil }
            if !text.isEmpty {
                spoken = Self.last(Self.liveLimit, of: Self.joining(spoken, text))
                remember(text, at: now)
            }
        } else {
            pending = (update.segmentID, text)
        }
        live = Self.last(Self.liveLimit, of: Self.joining(spoken, pending?.text ?? ""))
    }

    /// Forgets the segment still being recognized: its engine stopped.
    mutating func dropPending() {
        pending = nil
        live = Self.last(Self.liveLimit, of: spoken)
    }

    /// The final texts of the last half minute and then `text`, joined with spaces: at most `excerptLimit` characters,
    /// starting with "…" when it was cut. Nil when there is nothing.
    func excerpt(endingWith text: String, at now: Date) -> String? {
        var parts = finals.filter { Self.isRecent($0.date, now: now) }.map(\.text)
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { parts.append(current) }
        let joined = parts.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        guard joined.count > Self.excerptLimit else { return joined }
        return "\u{2026}" + joined.suffix(Self.excerptLimit - 1).drop(while: \.isWhitespace)
    }

    private mutating func remember(_ text: String, at now: Date) {
        finals.removeAll { !Self.isRecent($0.date, now: now) }
        finals.append((now, text))
        var kept = finals.reduce(0) { $0 + $1.text.count + 1 }
        while kept > Self.keptLimit, finals.count > 1 {
            kept -= finals.removeFirst().text.count + 1
        }
    }

    /// Within the last half minute. A time after `now` (the clock was set back) does not count.
    private static func isRecent(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= excerptWindow
    }

    private static func joining(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    private static func last(_ count: Int, of text: String) -> String {
        text.count > count ? String(text.suffix(count)) : text
    }
}

/// Waits for calls into capture sources and engines, without being stuck behind one that hangs.
private enum TimeLimit {
    /// Runs `operation` in a task of its own and waits for it for at most `limit`, even when the calling task is
    /// cancelled meanwhile: what was started must be known, so that it can be stopped. Nil when time ran out; the
    /// operation then goes on by itself, and `late` gets its result if it ever ends.
    static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async -> T,
        late: @escaping @Sendable (T) async -> Void = { _ in }
    ) async -> T? {
        let race = TimeRace<T>()
        return await withCheckedContinuation { continuation in
            race.begin(continuation)
            Task {
                let value = await operation()
                if !race.finish(with: value) { await late(value) }
            }
            race.arm(
                Task {
                    try? await Task.sleep(for: limit)
                    race.expire()
                })
        }
    }
}

/// An operation against the clock: whichever ends first resumes the waiting caller, once.
private final class TimeRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<T?, Never>?
    private var timer: Task<Void, Never>?
    private var isOver = false

    func begin(_ continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Hands the operation's value over, unless time ran out first. Returns whether it was handed over.
    func finish(with value: T) -> Bool {
        let (continuation, timer) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?) in
            guard !isOver else { return (nil, nil) }
            isOver = true
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer)
        }
        guard let continuation else { return false }
        timer?.cancel()
        continuation.resume(returning: value)
        return true
    }

    func expire() {
        let continuation = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            guard !isOver else { return nil }
            isOver = true
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return self.continuation
        }
        continuation?.resume(returning: nil)
    }

    /// Keeps the timer, so that an operation that ends first can cancel it.
    func arm(_ timer: Task<Void, Never>) {
        let isOver = lock.withLock { () -> Bool in
            if !self.isOver { self.timer = timer }
            return self.isOver
        }
        if isOver { timer.cancel() }
    }
}

/// Waits for slow work that a command may cut short.
private enum Abandonable {
    /// Runs `operation` in a task of its own and waits for its result, unless the calling task is cancelled first:
    /// then the operation is cancelled as well, nil comes back at once, and `afterwards` runs once the operation is
    /// over, to clean up after it.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T, afterwards: @escaping @Sendable () async -> Void
    ) async -> Result<T, any Error>? {
        let (results, report) = AsyncStream.makeStream(
            of: Result<T, any Error>.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task {
            do {
                report.yield(.success(try await operation()))
            } catch {
                report.yield(.failure(error))
            }
            report.finish()
        }
        for await result in results { return result }
        work.cancel()
        Task {
            await work.value
            await afterwards()
        }
        return nil
    }
}
