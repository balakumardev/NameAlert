import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import os

// Stand-ins for everything `ListeningController` depends on. They do exactly what a test scripts, count what they
// were asked to do, and never touch a device, a file the test did not make, or the network.

// MARK: - Time

/// A clock the test moves by hand.
final class TestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)
    private let offset = OSAllocatedUnfairLock(initialState: 0.0)

    var now: Date { Self.start.addingTimeInterval(offset.withLock { $0 }) }

    func advance(by seconds: Double) {
        offset.withLock { $0 += seconds }
    }
}

/// A door that holds callers back until the test opens it. Once open, it stays open. A caller whose task is
/// cancelled while it waits is let go at once with `CancellationError`.
final class Gate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelledEarly: Set<UUID> = []
    }

    private enum Admission: Sendable { case pass, refuse, wait }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admission = state.withLock { state -> Admission in
                    if state.isOpen { return .pass }
                    if state.cancelledEarly.remove(id) != nil { return .refuse }
                    state.waiting[id] = continuation
                    return .wait
                }
                switch admission {
                case .pass: continuation.resume()
                case .refuse: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let continuation = state.waiting.removeValue(forKey: id) { return continuation }
                state.cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Like `wait()`, but deaf to cancellation, the way a stuck system call is.
    func waitIgnoringCancellation() async {
        await Task.detached { try? await self.wait() }.value
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.isOpen = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// The controller's `sleep`. It records every duration it is asked for. Durations of at least `gatedFrom` wait for
/// `gate` (and end early when cancelled); shorter ones really sleep, so that a 1 ms backoff takes 1 ms.
final class TestSleeper: Sendable {
    let gate = Gate()
    private let gatedFrom: Duration
    private let recorded = OSAllocatedUnfairLock(initialState: [Duration]())
    private let cancelled = OSAllocatedUnfairLock(initialState: 0)

    /// - Parameter gatedFrom: `.zero` holds every sleep at the gate; the default holds the snooze and the pause after
    ///   waking, and lets backoffs run.
    init(gatedFrom: Duration = .seconds(1)) {
        self.gatedFrom = gatedFrom
    }

    var durations: [Duration] { recorded.withLock { $0 } }
    /// Sleeps that ended early because their task was cancelled.
    var cancellations: Int { cancelled.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        recorded.withLock { $0.append(duration) }
        do {
            if duration >= gatedFrom {
                try await gate.wait()
            } else {
                try await Task.sleep(for: duration)
            }
        } catch {
            cancelled.withLock { $0 += 1 }
            throw error
        }
    }
}

// MARK: - Permissions

extension PermissionsSnapshot {
    static let allGranted = PermissionsSnapshot(
        microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .granted)

    func with(_ kind: PermissionKind, _ status: PermissionStatus) -> PermissionsSnapshot {
        var copy = self
        copy[kind] = status
        return copy
    }
}

final class FakePermissions: PermissionsProviding {
    private let current: OSAllocatedUnfairLock<PermissionsSnapshot>
    private let requested = OSAllocatedUnfairLock(initialState: [PermissionKind]())

    init(_ snapshot: PermissionsSnapshot = .allGranted) {
        current = OSAllocatedUnfairLock(initialState: snapshot)
    }

    var requests: [PermissionKind] { requested.withLock { $0 } }

    func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        current.withLock { $0[kind] = status }
    }

    func snapshot() async -> PermissionsSnapshot {
        current.withLock { $0 }
    }

    func request(_ kind: PermissionKind) async -> Bool {
        requested.withLock { $0.append(kind) }
        return current.withLock { $0[kind] == .granted }
    }
}

// MARK: - Capture

/// Makes capture sources that play a script, and counts what all of them were asked to do.
///
/// Run `n` (counting every `start()` of every source, from 0) plays `scripts[n]`, or the last script when there are
/// fewer. A source made by `make(_:)` is a new object each time, as the real factory's are.
final class FakeCapture: Sendable {
    enum Ending: Sendable {
        /// The stream stays open until the source is stopped.
        case stayOpen
        /// Capture fails right after the chunks.
        case fail(String)
        /// The user stops capture from the system's recording indicator right after the chunks.
        case stoppedByUser
        /// Capture fails once `failTrigger` opens.
        case failWhenTriggered(String)
    }

    struct Script: Sendable {
        var chunks = 1
        var ending = Ending.stayOpen
        /// `start()` does not return until `startGate` opens, like a capture that hangs while starting.
        var startHangs = false
        /// `start()` throws this instead of starting.
        var startError: AudioCaptureError?
        /// `stop()` of this run does not return until `stopGate` opens, like a capture that hangs while stopping.
        var stopHangs = false

        init(
            chunks: Int = 1, ending: Ending = .stayOpen, startHangs: Bool = false,
            startError: AudioCaptureError? = nil, stopHangs: Bool = false
        ) {
            self.chunks = chunks
            self.ending = ending
            self.startHangs = startHangs
            self.startError = startError
            self.stopHangs = stopHangs
        }
    }

    private struct State: Sendable {
        var scripts: [Script]
        var madeKinds: [AudioSourceKind] = []
        var startCount = 0
        var stopCount = 0
        var startsInFlight = 0
        var stopsInFlight = 0
        var activeRuns = 0
    }

    let startGate = Gate()
    let stopGate = Gate()
    let failTrigger = Gate()
    private let state: OSAllocatedUnfairLock<State>

    init(_ scripts: [Script] = [Script()]) {
        state = OSAllocatedUnfairLock(initialState: State(scripts: scripts.isEmpty ? [Script()] : scripts))
    }

    var madeKinds: [AudioSourceKind] { state.withLock { $0.madeKinds } }
    var startCount: Int { state.withLock { $0.startCount } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    /// `start()` calls that have not returned yet.
    var startsInFlight: Int { state.withLock { $0.startsInFlight } }
    /// `stop()` calls that hang and have not returned yet.
    var stopsInFlight: Int { state.withLock { $0.stopsInFlight } }
    /// Runs that started and have not ended: pipelines holding a device.
    var activeRuns: Int { state.withLock { $0.activeRuns } }

    func make(_ kind: AudioSourceKind) -> any AudioCaptureSource {
        state.withLock { $0.madeKinds.append(kind) }
        return FakeSource(capture: self)
    }

    fileprivate func beginStart() -> Script {
        state.withLock { state in
            let script = state.scripts[min(state.startCount, state.scripts.count - 1)]
            state.startCount += 1
            state.startsInFlight += 1
            return script
        }
    }

    fileprivate func startReturned(running: Bool) {
        state.withLock { state in
            state.startsInFlight -= 1
            if running { state.activeRuns += 1 }
        }
    }

    fileprivate func stopped() {
        state.withLock { $0.stopCount += 1 }
    }

    /// A `stop()` that hangs: it returns once `stopGate` opens, whether or not its task is cancelled.
    fileprivate func hangWhileStopping() async {
        state.withLock { $0.stopsInFlight += 1 }
        await stopGate.waitIgnoringCancellation()
        state.withLock { $0.stopsInFlight -= 1 }
    }

    fileprivate func runEnded() {
        state.withLock { $0.activeRuns -= 1 }
    }
}

private final class FakeSource: AudioCaptureSource {
    private struct Run: Sendable {
        var continuation: AsyncStream<AudioChunk>.Continuation?
        var endReason: CaptureEndReason?
        var stopHangs = false
    }

    private let capture: FakeCapture
    private let run = OSAllocatedUnfairLock(initialState: Run())

    init(capture: FakeCapture) {
        self.capture = capture
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let script = capture.beginStart()
        if script.startHangs { await capture.startGate.waitIgnoringCancellation() }
        if let error = script.startError {
            capture.startReturned(running: false)
            throw error
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        run.withLock { $0 = Run(continuation: continuation, endReason: nil, stopHangs: script.stopHangs) }
        capture.startReturned(running: true)
        let capture = capture
        Task {
            for sequence in 0..<script.chunks {
                continuation.yield(AudioChunk(samples: [Float](repeating: 0.1, count: 1_600), sequence: UInt64(sequence)))
            }
            switch script.ending {
            case .stayOpen: return
            case .fail(let message): self.end(.failed(message))
            case .stoppedByUser: self.end(.stoppedByUser)
            case .failWhenTriggered(let message):
                await capture.failTrigger.waitIgnoringCancellation()
                self.end(.failed(message))
            }
        }
        return stream
    }

    func stop() async {
        capture.stopped()
        if run.withLock({ $0.stopHangs }) { await capture.hangWhileStopping() }
        end(.stopped)
    }

    func endReason() async -> CaptureEndReason? {
        run.withLock { $0.endReason }
    }

    /// Ends the current run, once: the first reason stays.
    private func end(_ reason: CaptureEndReason) {
        let continuation = run.withLock { run -> AsyncStream<AudioChunk>.Continuation? in
            guard let continuation = run.continuation else { return nil }
            run.continuation = nil
            run.endReason = reason
            return continuation
        }
        guard let continuation else { return }
        continuation.finish()
        capture.runEnded()
    }
}

// MARK: - Speech

/// Makes speech engines that emit scripted updates as audio arrives, and records what all of them were asked to do.
///
/// Transcription run `n` (counting every `transcribe` of every engine, from 0) plays `scripts[n]`, or the last
/// script when there are fewer: on the k-th chunk it emits update k, if there is one.
final class FakeSpeech: Sendable {
    struct Script: Sendable {
        var updates: [TranscriptUpdate] = []
        /// After this many chunks, the stream fails with `failure`.
        var failAfterChunks: Int?
        var failure = SpeechEngineError.engineFailed("The recognizer crashed")
        /// Emitted `lateDelay` after the audio ends, the way a final result for the last words comes.
        var late: TranscriptUpdate?
        var lateDelay: Duration = .milliseconds(50)
        /// The stream does not end when the audio does, only when it is cancelled: an engine that never finishes.
        var staysOpenAfterAudio = false

        init(
            _ updates: [TranscriptUpdate] = [], failAfterChunks: Int? = nil,
            failure: SpeechEngineError = .engineFailed("The recognizer crashed"), late: TranscriptUpdate? = nil,
            lateDelay: Duration = .milliseconds(50), staysOpenAfterAudio: Bool = false
        ) {
            self.updates = updates
            self.failAfterChunks = failAfterChunks
            self.failure = failure
            self.late = late
            self.lateDelay = lateDelay
            self.staysOpenAfterAudio = staysOpenAfterAudio
        }
    }

    private struct State: Sendable {
        var scripts: [Script]
        var madeIDs: [EngineID] = []
        var preparedLocales: [String] = []
        var preparedHints: [[String]] = []
        var hintUpdates: [[String]] = []
        var stopCount = 0
        var transcribeCount = 0
        var activeRuns = 0
        var prepareError: SpeechEngineError?
        var prepareProgress: [PreparationProgress] = []
    }

    let prepareGate = Gate()
    private let state: OSAllocatedUnfairLock<State>
    private let holdsPrepare: Bool

    init(_ scripts: [Script] = [Script()], holdsPrepare: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(scripts: scripts.isEmpty ? [Script()] : scripts))
        self.holdsPrepare = holdsPrepare
    }

    var madeIDs: [EngineID] { state.withLock { $0.madeIDs } }
    var prepareCount: Int { state.withLock { $0.preparedLocales.count } }
    var preparedLocales: [String] { state.withLock { $0.preparedLocales } }
    var preparedHints: [[String]] { state.withLock { $0.preparedHints } }
    var hintUpdates: [[String]] { state.withLock { $0.hintUpdates } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var transcribeCount: Int { state.withLock { $0.transcribeCount } }
    /// Transcriptions that have started and not finished.
    var activeRuns: Int { state.withLock { $0.activeRuns } }

    func failPrepare(with error: SpeechEngineError?) {
        state.withLock { $0.prepareError = error }
    }

    func reportWhilePreparing(_ progress: [PreparationProgress]) {
        state.withLock { $0.prepareProgress = progress }
    }

    func make(_ id: EngineID) -> any SpeechEngine {
        state.withLock { $0.madeIDs.append(id) }
        return FakeEngine(id: id, speech: self)
    }

    fileprivate func prepare(
        locale: String, hints: [String], progress: @Sendable (PreparationProgress) -> Void
    ) async throws {
        let (error, reports) = state.withLock { state in
            state.preparedLocales.append(locale)
            state.preparedHints.append(hints)
            return (state.prepareError, state.prepareProgress)
        }
        for report in reports { progress(report) }
        // Deaf to cancellation while held, like an install of Apple's speech files.
        if holdsPrepare { await prepareGate.waitIgnoringCancellation() }
        if let error { throw error }
    }

    fileprivate func beginRun() -> Script {
        state.withLock { state in
            let script = state.scripts[min(state.transcribeCount, state.scripts.count - 1)]
            state.transcribeCount += 1
            state.activeRuns += 1
            return script
        }
    }

    fileprivate func endRun() {
        state.withLock { $0.activeRuns -= 1 }
    }

    fileprivate func updatedHints(_ hints: [String]) {
        state.withLock { $0.hintUpdates.append(hints) }
    }

    fileprivate func stopped() {
        state.withLock { $0.stopCount += 1 }
    }
}

private struct FakeEngine: SpeechEngine {
    let id: EngineID
    let speech: FakeSpeech

    func prepare(
        localeIdentifier: String, hints: [String], progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        try await speech.prepare(locale: localeIdentifier, hints: hints, progress: progress)
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        let script = speech.beginRun()
        let speech = speech
        let (updates, output) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        let work = Task {
            defer { speech.endRun() }
            var heard = 0
            for await _ in audio {
                if heard < script.updates.count { output.yield(script.updates[heard]) }
                heard += 1
                if let limit = script.failAfterChunks, heard >= limit {
                    output.finish(throwing: script.failure)
                    return
                }
            }
            if let late = script.late, (try? await Task.sleep(for: script.lateDelay)) != nil {
                output.yield(late)
            }
            if script.staysOpenAfterAudio {
                try? await Task.sleep(for: .seconds(3_600))  // until the reader goes away and cancels this
            }
            output.finish()
        }
        output.onTermination = { _ in work.cancel() }
        return updates
    }

    func updateHints(_ hints: [String]) async {
        speech.updatedHints(hints)
    }

    func stop() async {
        speech.stopped()
    }
}

// MARK: - Models

/// Model files in memory. Downloads can be held until the test lets them go; deleting a model while its download is
/// held makes that download throw `CancellationError`, as `ModelManager` does.
final class FakeModels: ModelProviding {
    private struct State: Sendable {
        var installed: Set<WhisperModel>
        var holdsDownloads: Bool
        var downloads: [WhisperModel] = []
        var deletes: [WhisperModel] = []
        var held: [UUID: Held] = [:]
        var cancelledEarly: Set<UUID> = []
    }

    private struct Held: Sendable {
        let model: WhisperModel
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum Admission: Sendable { case pass, refuse, wait }

    private let state: OSAllocatedUnfairLock<State>

    init(installed: Set<WhisperModel> = Set(WhisperModel.allCases), holdsDownloads: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(installed: installed, holdsDownloads: holdsDownloads))
    }

    var downloads: [WhisperModel] { state.withLock { $0.downloads } }
    var deletes: [WhisperModel] { state.withLock { $0.deletes } }
    var heldDownloads: Int { state.withLock { $0.held.count } }

    func isInstalled(_ model: WhisperModel) async -> Bool {
        state.withLock { $0.installed.contains(model) }
    }

    func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let installed = state.withLock { state -> Bool in
            state.downloads.append(model)
            return state.installed.contains(model)
        }
        if installed {
            progress(1)
            return
        }
        progress(0.5)
        try await waitWhileHeld(model)
        state.withLock { _ = $0.installed.insert(model) }
        progress(1)
    }

    func delete(_ model: WhisperModel) async throws {
        let stopped = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.deletes.append(model)
            state.installed.remove(model)
            let ids = state.held.filter { $0.value.model == model }.map(\.key)
            return ids.compactMap { state.held.removeValue(forKey: $0)?.continuation }
        }
        for continuation in stopped { continuation.resume(throwing: CancellationError()) }
    }

    /// Lets every held download finish, and the ones that come later run straight through.
    func releaseDownloads() {
        let held = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.holdsDownloads = false
            defer { state.held = [:] }
            return state.held.values.map(\.continuation)
        }
        for continuation in held { continuation.resume() }
    }

    private func waitWhileHeld(_ model: WhisperModel) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admission = state.withLock { state -> Admission in
                    if !state.holdsDownloads { return .pass }
                    if state.cancelledEarly.remove(id) != nil { return .refuse }
                    state.held[id] = Held(model: model, continuation: continuation)
                    return .wait
                }
                switch admission {
                case .pass: continuation.resume()
                case .refuse: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let held = state.held.removeValue(forKey: id) { return held.continuation }
                state.cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Calls

/// The call states the test sends. Each subscription gets a new stream; the test speaks to the newest one.
final class FakeCallStates: Sendable {
    private struct State: Sendable {
        var continuations: [AsyncStream<CallState>.Continuation] = []
        var terminations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var subscriptions: Int { state.withLock { $0.continuations.count } }
    /// Subscriptions whose consumer has gone away.
    var terminations: Int { state.withLock { $0.terminations } }

    func subscribe() -> AsyncStream<CallState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CallState.self)
        continuation.onTermination = { [state] _ in state.withLock { $0.terminations += 1 } }
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }

    func send(_ callState: CallState) {
        let latest = state.withLock { $0.continuations.last }
        latest?.yield(callState)
    }
}

// MARK: - Alerts

/// A channel that records the hits it was given. One made with `holdsDeliveries` is a slow channel: each delivery
/// waits until `gate` opens (and ends with `CancellationError` if it is cancelled first).
final class FakeChannel: AlertChannel {
    private struct State: Sendable {
        var hits: [Hit] = []
        var finished = 0
        var cancelled = 0
    }

    let kind: ChannelKind
    let gate = Gate()
    private let holdsDeliveries: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ kind: ChannelKind, holdsDeliveries: Bool = false) {
        self.kind = kind
        self.holdsDeliveries = holdsDeliveries
    }

    /// Every hit it was asked to deliver, as soon as it was asked.
    var hits: [Hit] { state.withLock { $0.hits } }
    /// Deliveries that are over.
    var finished: Int { state.withLock { $0.finished } }
    /// Deliveries that were cancelled while they waited.
    var cancelled: Int { state.withLock { $0.cancelled } }

    func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        state.withLock { $0.hits.append(hit) }
        defer { state.withLock { $0.finished += 1 } }
        guard holdsDeliveries else { return }
        do {
            try await gate.wait()
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
    }
}

// MARK: - Capabilities

extension EngineCapabilities {
    /// macOS 26 on Apple silicon: `SpeechTranscriber` for English.
    static let analyzer = EngineCapabilities(
        osMajorVersion: 26, speechTranscriberAvailable: true, speechTranscriberLocales: ["en-US"],
        dictationTranscriberLocales: ["en-US"], sfSpeechOnDeviceLocales: ["en-US"], isAppleSilicon: true)

    /// macOS 15: only `SFSpeechRecognizer`.
    static let sfSpeechOnly = EngineCapabilities(
        osMajorVersion: 15, speechTranscriberAvailable: false, speechTranscriberLocales: [],
        dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: ["en-US"], isAppleSilicon: true)

    /// No Apple engine at all: Automatic falls back to the local model.
    static let noAppleSpeech = EngineCapabilities(
        osMajorVersion: 14, speechTranscriberAvailable: false, speechTranscriberLocales: [],
        dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: [], isAppleSilicon: true)
}
