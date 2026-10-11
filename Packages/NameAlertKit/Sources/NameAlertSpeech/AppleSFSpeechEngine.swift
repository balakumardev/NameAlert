import AVFoundation
import Foundation
import NameAlertCore
import Speech
import os

/// Listens with Apple's `SFSpeechRecognizer`, on the device only (spec section 8.4). It is the Apple engine on
/// macOS 14 and 15, and for languages that `SpeechAnalyzer` does not have.
///
/// **On the device.** Every request sets `requiresOnDeviceRecognition`, so the audio never leaves the Mac, and
/// `prepare` refuses a language this Mac cannot recognize offline. It also refuses to go on without the speech
/// recognition permission; asking for it is the caller's job.
///
/// **Rotation.** A recognition task is meant for about a minute of audio, so the engine keeps replacing it. After
/// 50 s of audio in the current task, a new task starts, primed with the last 1.5 s of audio so that a word on the
/// boundary is heard whole, and only then is the old task told that its audio has ended. The old task still reports
/// its last words and is cancelled 2 s later. A task that is done by itself (a final result) or has failed is
/// replaced at once. `SFSpeechSession` keeps this bookkeeping; the engine carries out what it decides.
///
/// **What is reported.** Each task is one segment, `sf<n>`, where `n` counts the tasks of a transcription from 1.
/// Its text is everything the task has heard so far (`bestTranscription`), with up to 3 other readings, so repeated
/// mentions within one task are told apart by their order (see `RuleEngine`). A task that ends without a final
/// result has its last reading reported again as final: every segment ends with a final update. The names to listen
/// for become each request's contextual strings; a change applies from the next task on.
///
/// **Giving up.** A task that fails before it heard anything, within its first 2 s of new audio, failed quickly.
/// After 3 quick failures in a row the stream ends with `engineFailed`, so the caller restarts the engine instead of
/// it starting doomed tasks forever. One exception: a new task that fails at once while the old one is still
/// finishing may have been refused because of it (Apple documents an error for starting "while an earlier instance
/// is still active"), so the old one is let go at once and a new task starts, without counting it.
///
/// **Threads.** The recognizer calls back on its own serial queue. Those callbacks, the audio and the timers all
/// become events on one stream, which a single loop on the actor handles in order, so the framework's objects are
/// only ever used there. `transcribe` returns at once and records its run under a lock, so a `stop` right after it
/// always ends that run, as in `WhisperEngine`.
public actor AppleSFSpeechEngine: SpeechEngine {
    public nonisolated let id = EngineID.appleSFSpeech

    private typealias Output = AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation

    private let logger = Log.logger("sfspeech")
    /// From `prepare` until `stop`.
    private var recognizer: SFSpeechRecognizer?
    /// The names to listen for. Each new task takes the latest.
    private var hints: [String] = []
    /// Counts the calls to `prepare` and `stop`. A `prepare` that finds it changed was overtaken by a later call.
    private var generation: UInt64 = 0
    /// The latest `transcribe`, until `stop` or the next `transcribe` ends it.
    private nonisolated let latestRun = OSAllocatedUnfairLock<TranscriptionRun?>(initialState: nil)

    public init() {}

    // MARK: SpeechEngine

    /// Checks that this Mac can recognize the language on the device and that speech recognition is allowed, and gets
    /// the recognizer ready. A running transcription is ended first. `progress` is never called: nothing is
    /// downloaded.
    ///
    /// Throws `unsupportedLocale` when there is no on-device recognizer for the language, `permissionDenied` when
    /// speech recognition is not allowed (it does not ask), and `CancellationError` when `stop` or another `prepare`
    /// came along meanwhile.
    public func prepare(
        localeIdentifier: String, hints: [String],
        progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        generation &+= 1
        let mine = generation
        await shutDown()
        guard generation == mine, !Task.isCancelled else { throw CancellationError() }

        let locale = Locale(identifier: localeIdentifier)
        // For a language it does not know, the initializer may fall back to the dictation language: check it is this one.
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition,
            recognizer.locale.language.languageCode == locale.language.languageCode
        else { throw SpeechEngineError.unsupportedLocale(localeIdentifier) }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw SpeechEngineError.permissionDenied }

        let queue = OperationQueue()
        queue.name = "dev.balakumar.namealert.sfspeech"
        queue.maxConcurrentOperationCount = 1  // one task's callbacks in the order they come
        queue.qualityOfService = .userInitiated
        recognizer.queue = queue
        self.recognizer = recognizer
        self.hints = hints
        logger.info("Ready to recognize \(recognizer.locale.identifier, privacy: .public) on this Mac")
    }

    /// Recognizes the audio and streams what each recognition task hears (see the type's notes).
    ///
    /// One transcription runs at a time: a new call ends the stream of the one before. When the audio ends, the engine
    /// waits up to 10 s for the last results and then finishes the stream. When the caller stops listening, the work
    /// stops. The stream fails with `engineFailed` when the engine is not prepared, or when the recognizer keeps
    /// failing.
    public nonisolated func transcribe(
        _ audio: AsyncStream<AudioChunk>
    ) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        let (updates, output) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        let run = TranscriptionRun(output: output)
        output.onTermination = { _ in run.cancel() }
        let previous = latestRun.withLock { latest in
            defer { latest = run }
            return latest
        }
        previous?.end()
        run.start(
            Task {
                await previous?.finished()  // one transcription at a time on the recognizer
                await self.process(audio, for: run)
            })
        return updates
    }

    /// Replaces the names to listen for. The next recognition task uses them.
    public func updateHints(_ hints: [String]) async {
        self.hints = hints
    }

    /// Ends the running transcription (its stream finishes, its tasks are cancelled), waits for it to return, and lets
    /// the recognizer go. Stopping a stopped engine does nothing.
    public func stop() async {
        generation &+= 1
        await shutDown()
        recognizer = nil
    }

    // MARK: Running

    /// Ends the latest transcription and waits for its loop to return.
    private func shutDown() async {
        let run = latestRun.withLock { latest in
            defer { latest = nil }
            return latest
        }
        run?.end()
        await run?.finished()
    }

    /// The work of one `transcribe`: hands every event to the session and carries out what it decides, until the
    /// session is done or the run is ended.
    private func process(_ audio: AsyncStream<AudioChunk>, for run: TranscriptionRun) async {
        guard !Task.isCancelled else {
            run.output.finish()
            return
        }
        guard let recognizer, let format = MonoAudio.makeFormat() else {
            run.output.finish(throwing: SpeechEngineError.engineFailed("Apple speech recognition is not ready."))
            return
        }

        let (events, eventInput) = AsyncStream.makeStream(of: SFSpeechSession.Event.self)
        // The audio becomes events as well, so that everything is handled in one place, in order.
        let reader = Task {
            for await chunk in audio { eventInput.yield(.audio(chunk.samples)) }
            if !Task.isCancelled { eventInput.yield(.audioEnded) }
        }
        let tasks = RecognitionTasks(recognizer: recognizer, format: format, events: eventInput)
        var session = SFSpeechSession()
        perform(session.start(), on: tasks, output: run.output)
        if !session.isDone {
            for await event in events {
                if case .failure(let task, let reason) = event, session.isLive(task) {
                    logger.notice("Recognition task \(task) failed: \(reason, privacy: .public)")
                }
                perform(session.handle(event), on: tasks, output: run.output)
                if session.isDone { break }
            }
        }

        // Done, or ended by `stop`, a new transcription or the caller going away.
        reader.cancel()
        tasks.cancelAll()
        eventInput.finish()
        run.output.finish()
    }

    /// Carries out the session's actions, in order.
    private func perform(_ actions: [SFSpeechSession.Action], on tasks: RecognitionTasks, output: Output) {
        for action in actions {
            switch action {
            case .startTask(let task, let primer):
                tasks.start(task, primer: primer, hints: hints)
                logger.debug("Started recognition task \(task)")
            case .append(let task, let samples):
                tasks.append(samples, to: task)
            case .endAudio(let task):
                tasks.endAudio(of: task)
            case .cancel(let task):
                tasks.cancel(task)
            case .scheduleRetirement(let task, let delay):
                tasks.schedule(.retireDue(generation: task), after: delay)
            case .scheduleDrainTimeout(let delay):
                tasks.schedule(.drainTimedOut, after: delay)
            case .report(let update):
                logger.debug("Heard in \(update.segmentID, privacy: .public): \(update.text, privacy: .private)")
                output.yield(update)
            case .finish:
                output.finish()
            case .fail(let error):
                logger.error("Apple speech recognition stopped after failing again and again")
                output.finish(throwing: error)
            }
        }
    }
}

// MARK: - The framework's side

/// The recognition tasks of one transcription, and the session's timers. Only the engine's loop uses it.
private final class RecognitionTasks {
    private struct Running {
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    private let recognizer: SFSpeechRecognizer
    private let format: AVAudioFormat
    private let events: AsyncStream<SFSpeechSession.Event>.Continuation
    private var running: [UInt64: Running] = [:]
    /// The retirement timer of each task that has one, and the drain timer under the key `nil`.
    private var timers: [UInt64?: Task<Void, Never>] = [:]

    init(recognizer: SFSpeechRecognizer, format: AVAudioFormat, events: AsyncStream<SFSpeechSession.Event>.Continuation) {
        self.recognizer = recognizer
        self.format = format
        self.events = events
    }

    /// Starts recognition task `generation` and gives it `primer` first.
    func start(_ generation: UInt64, primer: [Float], hints: [String]) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // the audio never leaves the Mac
        request.shouldReportPartialResults = true
        request.contextualStrings = Array(hints.prefix(100))
        request.addsPunctuation = false
        let task = recognizer.recognitionTask(
            with: request, resultHandler: Self.resultHandler(for: generation, events: events))
        running[generation] = Running(request: request, task: task)
        append(primer, to: generation)
    }

    func append(_ samples: [Float], to generation: UInt64) {
        guard let request = running[generation]?.request, let buffer = MonoAudio.buffer(samples, format: format)
        else { return }
        request.append(buffer)
    }

    func endAudio(of generation: UInt64) {
        running[generation]?.request.endAudio()
    }

    /// Cancels the task and forgets it, with its retirement timer.
    func cancel(_ generation: UInt64) {
        timers.removeValue(forKey: generation)?.cancel()
        running.removeValue(forKey: generation)?.task.cancel()
    }

    /// Sends `event` to the loop after `delay`. A `.retireDue` timer belongs to its task; any other is the drain timer.
    func schedule(_ event: SFSpeechSession.Event, after delay: Duration) {
        let key: UInt64? =
            if case .retireDue(let generation) = event { generation } else { nil }
        let events = self.events
        timers[key]?.cancel()
        timers[key] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            events.yield(event)
        }
    }

    func cancelAll() {
        for generation in Array(running.keys) { cancel(generation) }
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    /// What one task's callbacks become: events for the loop. It is made here, away from the actor, so the closure is
    /// not tied to the actor; the recognizer calls it on its own queue.
    private static func resultHandler(
        for generation: UInt64, events: AsyncStream<SFSpeechSession.Event>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            if let result {
                events.yield(.result(generation: generation, SFSpeechSession.Recognized(result)))
            }
            if let error {
                let error = error as NSError
                events.yield(.failure(generation: generation, reason: "\(error.domain) \(error.code)"))
            }
        }
    }
}

extension SFSpeechSession.Recognized {
    /// What `result` says the task heard: its best transcription, and the others as alternatives.
    init(_ result: SFSpeechRecognitionResult) {
        let text = Readings.text(result.bestTranscription.formattedString)
        self.init(
            text: text,
            alternatives: Readings.alternatives(result.transcriptions.map(\.formattedString), besides: text),
            isFinal: result.isFinal)
    }
}

// MARK: - The bookkeeping

/// The SFSpeech engine's bookkeeping for one transcription, apart from the framework so that tests can drive it:
/// which recognition task gets the audio, when the next one starts, what is reported, and when it is over.
///
/// The engine hands it events one at a time (the audio, what the tasks report, its timers) and carries out the actions
/// it returns, in order. Tasks are numbered from 1, and a task's number is also its segment ID (`sf<n>`). See
/// `AppleSFSpeechEngine` for the rules.
struct SFSpeechSession {
    /// What a task reported hearing.
    struct Recognized: Sendable, Equatable {
        let text: String
        let alternatives: [String]
        let isFinal: Bool
    }

    enum Event: Sendable, Equatable {
        /// The next piece of audio.
        case audio([Float])
        /// The audio has ended: no more is coming.
        case audioEnded
        /// Task `generation` reported what it heard.
        case result(generation: UInt64, Recognized)
        /// Task `generation` failed, for `reason`.
        case failure(generation: UInt64, reason: String)
        /// Task `generation`, which was told its audio has ended, has had its time.
        case retireDue(generation: UInt64)
        /// The audio ended long enough ago: stop waiting for the last results.
        case drainTimedOut
    }

    enum Action: Sendable, Equatable {
        /// Start task `generation` and give it `primer`, the audio just before it, first.
        case startTask(generation: UInt64, primer: [Float])
        /// Give the task more audio.
        case append(generation: UInt64, [Float])
        /// Tell the task that no more audio is coming. It goes on reporting what it heard.
        case endAudio(generation: UInt64)
        /// Cancel the task and let it go. Nothing it reports afterwards counts.
        case cancel(generation: UInt64)
        /// Send `.retireDue(generation)` after `after`.
        case scheduleRetirement(generation: UInt64, after: Duration)
        /// Send `.drainTimedOut` after `after`.
        case scheduleDrainTimeout(after: Duration)
        /// Pass this on to the caller.
        case report(TranscriptUpdate)
        /// The transcription is over: finish the stream.
        case finish
        /// The transcription failed: finish the stream with this error.
        case fail(SpeechEngineError)
    }

    /// How long a task that was told its audio has ended may still report before it is cancelled.
    static let retirementDelay = Duration.seconds(2)
    /// How long to wait for the last results once the audio has ended.
    static let drainTimeout = Duration.seconds(10)
    /// A task that fails before it heard anything and before it had this much new audio (2 s) failed quickly.
    static let quickFailureSamples = 32_000
    /// After this many quick failures in a row, the transcription fails.
    static let maxQuickFailures = 3

    private struct TaskState {
        /// What it reported last, if anything.
        var lastReading: Recognized?
        /// The audio it got after its primer, in samples.
        var newSamples = 0
    }

    private var policy: RotationPolicy
    private var ring: AudioRingBuffer
    private var nextGeneration: UInt64 = 1
    /// The task that gets the audio. Nil until `start`.
    private var current: UInt64?
    /// The tasks that have not been let go: the current one, and older ones that may still report.
    private var tasks: [UInt64: TaskState] = [:]
    private var quickFailures = 0
    private var audioEnded = false
    /// True once the transcription has finished or failed. Events after that change nothing.
    private(set) var isDone = false

    init(policy: RotationPolicy = RotationPolicy(), ring: AudioRingBuffer = AudioRingBuffer()) {
        self.policy = policy
        self.ring = ring
    }

    /// Whether task `generation` still counts: it has not been let go.
    func isLive(_ generation: UInt64) -> Bool {
        tasks[generation] != nil
    }

    /// Starts the first task. Only the first call does anything.
    mutating func start() -> [Action] {
        guard current == nil, !isDone else { return [] }
        return startTask()
    }

    /// What to do about `event`.
    mutating func handle(_ event: Event) -> [Action] {
        guard !isDone, current != nil else { return [] }
        switch event {
        case .audio(let samples):
            return receive(samples)
        case .audioEnded:
            return endOfAudio()
        case .result(let generation, let reading):
            return receive(reading, from: generation)
        case .failure(let generation, let reason):
            return failure(of: generation, reason: reason)
        case .retireDue(let generation):
            return retire(generation)
        case .drainTimedOut:
            return audioEnded ? finish(with: .finish) : []
        }
    }

    // MARK: Events

    private mutating func receive(_ samples: [Float]) -> [Action] {
        guard !audioEnded, !samples.isEmpty, let current else { return [] }
        ring.append(samples)
        tasks[current]?.newSamples += samples.count
        var actions: [Action] = [.append(generation: current, samples)]
        if policy.shouldRotate(after: .audio(samples: samples.count)) {
            // Seamless: the new task is running before the old one is told to wrap up.
            actions += startTask()
            actions += [
                .endAudio(generation: current),
                .scheduleRetirement(generation: current, after: Self.retirementDelay),
            ]
        }
        return actions
    }

    private mutating func receive(_ reading: Recognized, from generation: UInt64) -> [Action] {
        guard var task = tasks[generation] else { return [] }
        var actions: [Action] = []
        // An empty reading says nothing, unless it is the final word on text reported before.
        if !reading.text.isEmpty || (reading.isFinal && task.lastReading != nil) {
            actions.append(.report(update(reading, from: generation)))
            task.lastReading = reading
            tasks[generation] = task
        }
        if generation == current, !reading.text.isEmpty {
            quickFailures = 0  // the recognizer works
        }
        guard reading.isFinal else { return actions }

        // The task has said its last word.
        actions += close(generation)
        if generation == current, !audioEnded, policy.shouldRotate(after: .result(isFinal: true)) {
            actions += startTask()
        } else if audioEnded, tasks.isEmpty {
            actions += finish(with: .finish)
        }
        return actions
    }

    private mutating func failure(of generation: UInt64, reason: String) -> [Action] {
        guard let task = tasks[generation] else { return [] }
        var actions = close(generation)
        guard generation == current, !audioEnded else {
            // An old task, or the last one after the audio ended: nothing to replace.
            if audioEnded, tasks.isEmpty { actions += finish(with: .finish) }
            return actions
        }

        let quick = task.lastReading == nil && task.newSamples < Self.quickFailureSamples
        if quick, !tasks.isEmpty {
            // It failed at once while an older task was still finishing. The recognizer may run only one task at a
            // time: let the older ones go, and try again. This does not count against the recognizer.
            for older in tasks.keys.sorted() { actions += close(older) }
        } else if quick {
            quickFailures += 1
            if quickFailures >= Self.maxQuickFailures {
                return actions + finish(with: .fail(.engineFailed("Apple speech recognition keeps failing (\(reason)).")))
            }
        } else {
            quickFailures = 0
        }
        if policy.shouldRotate(after: .failure) {
            actions += startTask()
        }
        return actions
    }

    private mutating func retire(_ generation: UInt64) -> [Action] {
        guard generation != current else { return [] }
        var actions = close(generation)
        if audioEnded, tasks.isEmpty, !actions.isEmpty {
            actions += finish(with: .finish)
        }
        return actions
    }

    private mutating func endOfAudio() -> [Action] {
        guard !audioEnded, let current else { return [] }
        audioEnded = true
        guard tasks[current] != nil else { return finish(with: .finish) }
        return [.endAudio(generation: current), .scheduleDrainTimeout(after: Self.drainTimeout)]
    }

    // MARK: Helpers

    /// Starts the next task, primed with the audio in the ring buffer, and makes it the current one.
    private mutating func startTask() -> [Action] {
        let generation = nextGeneration
        nextGeneration += 1
        let primer = ring.contents
        current = generation
        tasks[generation] = TaskState()
        policy.rotated(primedSamples: primer.count)
        return [.startTask(generation: generation, primer: primer)]
    }

    /// Lets task `generation` go. If its last reading was not final, it is reported again as final, so its segment
    /// ends.
    private mutating func close(_ generation: UInt64) -> [Action] {
        guard let task = tasks.removeValue(forKey: generation) else { return [] }
        var actions: [Action] = []
        if let last = task.lastReading, !last.isFinal {
            let final = Recognized(text: last.text, alternatives: last.alternatives, isFinal: true)
            actions.append(.report(update(final, from: generation)))
        }
        actions.append(.cancel(generation: generation))
        return actions
    }

    /// Lets every task go and ends the transcription with `last` (`.finish` or `.fail`).
    private mutating func finish(with last: Action) -> [Action] {
        var actions: [Action] = []
        for generation in tasks.keys.sorted() { actions += close(generation) }
        isDone = true
        return actions + [last]
    }

    private func update(_ reading: Recognized, from generation: UInt64) -> TranscriptUpdate {
        TranscriptUpdate(
            segmentID: "sf\(generation)", text: reading.text, alternatives: reading.alternatives,
            isFinal: reading.isFinal)
    }
}
