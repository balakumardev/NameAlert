import Foundation
import NameAlertCore
import os

/// Listens with a whisper.cpp model on this Mac, for Macs that do not have Apple's on-device recognizer, Intel Macs
/// included (spec section 8.5).
///
/// **The pipeline.** One task per `transcribe` takes the audio in order. The whole 512-sample frames of each chunk go
/// through speech detection: the Silero model when it is installed and loads, `EnergyVAD` otherwise. Every frame and
/// its speech probability go into a `VADSegmenter`, and every segment it hands out is decoded by whisper before the
/// next chunk is read, so only speech is ever decoded. Detection runs as each chunk arrives (a chunk is three frames
/// and a bit; the bit waits for the next chunk), which adds at most 32 ms before a segment can close. When the audio
/// ends, the last partial frame (padded with silence) and the speech still open are decoded before the stream
/// finishes.
///
/// **Threads.** The models live in a `WhisperContext`, which makes every call into the C library on one serial
/// dispatch queue and lets the engine wait for it without blocking a thread. While a decode runs, the chunks that
/// arrive wait in the audio stream; the app keeps the newest 60 s of them for an engine that falls behind. The engine's
/// own state (the loaded models, the prompt) belongs to the actor. `transcribe` has to return at once, so it is not
/// isolated to the actor: it records its run under a lock, which is how a `stop` that comes right after it always
/// ends that run.
///
/// **What is reported.** One final update per segment, with the ID `w<first sample>` (counted from the start of the
/// stream) and no alternatives. A segment is dropped when whisper rates all of its text as more likely silence than
/// speech, and notes about non-speech such as "[BLANK_AUDIO]" are taken out (see `WhisperOutput`).
///
/// **Keeping up.** Each decode's time is compared with the length of its audio (`RealTimeGuard`). When the model
/// falls behind, `onFallingBehind` is called, and again on each later segment that is still too slow, at most once
/// every 30 s (`FallingBehindReporter`): an owner that takes its warning back after a quiet spell must not do so while
/// the model is still behind. While the Light model is behind, segments whose audio ended more than 10 s before the
/// live audio are skipped, so the engine catches up instead of reporting old speech late (only how many is logged).
/// In the app, the audio stream drops chunks older than 60 s, so an engine lags by about a minute at most.
///
/// **Lifetime.** `prepare` loads the models, `transcribe` runs one stream at a time (a new one ends the one before),
/// and `stop` ends the stream, waits for its task and frees the models. The engine can be prepared again after `stop`.
public actor WhisperEngine: SpeechEngine {
    public nonisolated let id: EngineID

    /// While the Light model is behind, a segment whose audio ended longer ago than this is skipped.
    static let maxSegmentAgeSeconds = 10.0
    /// A chunk that took longer than this to arrive was waited for, so it is live audio.
    static let waitedForChunk = Duration.milliseconds(20)

    private typealias Output = AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation

    private let size: LocalModelSize
    private let modelManager: ModelManager
    private let onFallingBehind: @Sendable () -> Void
    private let logger = Log.logger("whisper")

    /// The loaded models, from `prepare` until `stop`.
    private var context: WhisperContext?
    /// The names to listen for, as whisper's prompt.
    private var prompt: String?
    /// Counts the calls to `prepare` and `stop`. A `prepare` that finds it changed once its model has loaded was
    /// overtaken by a later call, and frees what it loaded.
    private var generation: UInt64 = 0
    /// The latest `transcribe`, until `stop` or the next `transcribe` ends it.
    private nonisolated let latestRun = OSAllocatedUnfairLock<TranscriptionRun?>(initialState: nil)

    /// `onFallingBehind` is called, from the engine, when the model starts falling behind the audio, and then at most
    /// every 30 s for as long as it stays behind.
    public init(size: LocalModelSize, modelManager: ModelManager, onFallingBehind: @escaping @Sendable () -> Void = {}) {
        self.id =
            switch size {
            case .light: .whisperLight
            case .balanced: .whisperBalanced
            }
        self.size = size
        self.modelManager = modelManager
        self.onFallingBehind = onFallingBehind
    }

    // MARK: SpeechEngine

    /// Loads the whisper model for the language (English-only for English, multilingual otherwise) and the Silero
    /// detector when it is installed. A running transcription is ended first.
    ///
    /// Throws `modelNotInstalled` when the whisper model is not on disk: downloading models is the caller's job, so
    /// `progress` is never called. Throws `unsupportedLocale` when the model has no such language, `engineFailed` when
    /// it does not load, and `CancellationError` when the calling task was cancelled, or `stop` or another `prepare`
    /// came along, while it loaded.
    public func prepare(
        localeIdentifier: String, hints: [String],
        progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        generation &+= 1
        let mine = generation
        await shutDown()

        let model = ModelCatalog.model(size: size, localeIdentifier: localeIdentifier)
        guard await modelManager.isInstalled(model) else { throw SpeechEngineError.modelNotInstalled }
        let modelFile = await modelManager.fileURL(for: model)
        var detectorFile: URL?
        if await modelManager.isInstalled(.vad) {
            detectorFile = await modelManager.fileURL(for: .vad)
        }
        let language = WhisperOptions.language(
            localeIdentifier: localeIdentifier, englishOnlyModel: model.isEnglishOnly)
        guard generation == mine, !Task.isCancelled else { throw CancellationError() }

        let loaded: WhisperContext
        do {
            loaded = try await WhisperContext.load(model: modelFile, speechDetectorModel: detectorFile, language: language)
        } catch WhisperContext.LoadError.unsupportedLanguage {
            throw SpeechEngineError.unsupportedLocale(localeIdentifier)
        } catch {
            logger.error("Could not load \(model.rawValue, privacy: .public)")
            throw SpeechEngineError.engineFailed("The local speech model could not be loaded.")
        }
        guard generation == mine, !Task.isCancelled else {
            await loaded.release()
            throw CancellationError()
        }

        context = loaded
        prompt = WhisperOptions.prompt(hints: hints)
        logger.info("Loaded \(model.rawValue, privacy: .public) for \(language, privacy: .public)")
        if detectorFile == nil {
            logger.info("The Silero speech detector is not installed; using the energy detector")
        } else if !loaded.hasSpeechDetector {
            logger.info("The Silero speech detector did not load; using the energy detector")
        }
    }

    /// Recognizes the audio and streams what whisper hears: one final update per stretch of speech.
    ///
    /// One transcription runs at a time: a new call ends the stream of the one before. When the audio ends, what is
    /// left is decoded and the stream finishes. When the caller stops listening, the work stops. The stream fails with
    /// `engineFailed` when the engine is not prepared, or when whisper.cpp fails.
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
                await previous?.finished()  // one transcription at a time on the models
                await self.process(audio, for: run)
            })
        return updates
    }

    /// Replaces the names to listen for, from the next segment on.
    public func updateHints(_ hints: [String]) async {
        prompt = WhisperOptions.prompt(hints: hints)
    }

    /// Ends the running transcription (its stream finishes), waits for its task to return, and frees the models.
    /// Stopping a stopped engine does nothing.
    public func stop() async {
        generation &+= 1
        await shutDown()
    }

    // MARK: Lifetime

    /// Ends the latest transcription and frees the models, once that transcription's task has returned.
    private func shutDown() async {
        let run = latestRun.withLock { latest in
            defer { latest = nil }
            return latest
        }
        run?.end()  // cancels its task, which also stops a decode that is running
        let released = context
        context = nil
        await run?.finished()
        await released?.release()
    }

    // MARK: Transcribing

    /// The work of one `transcribe`: listens to the audio and finishes the stream, with an error if there was one.
    private func process(_ audio: AsyncStream<AudioChunk>, for run: TranscriptionRun) async {
        guard !Task.isCancelled else {
            run.output.finish()
            return
        }
        guard let context else {
            run.output.finish(throwing: SpeechEngineError.engineFailed("The local speech model is not loaded."))
            return
        }
        do {
            try await listen(to: audio, with: context, into: run.output)
            run.output.finish()
        } catch is CancellationError {
            run.output.finish()
        } catch {
            run.output.finish(throwing: error)
        }
    }

    /// Takes the audio in order, chunk by chunk: detection, then the segmenter, then a decode of each segment.
    private func listen(to audio: AsyncStream<AudioChunk>, with context: WhisperContext, into output: Output) async throws {
        await context.resetSpeechDetector()
        var state = ListeningState(usesSileroDetector: context.hasSpeechDetector)
        let clock = ContinuousClock()
        let start = clock.now
        var chunks = audio.makeAsyncIterator()
        while true {
            let asked = clock.now
            guard let chunk = await chunks.next() else { break }
            let arrived = clock.now
            try Task.checkCancellation()
            state.lag = state.liveLag.update(
                sequence: chunk.sequence, at: (arrived - start).inSeconds,
                waited: arrived - asked > Self.waitedForChunk)
            state.received += Int64(chunk.samples.count)
            let block = state.frames.append(chunk.samples)
            try await consume(block, state: &state, context: context, output: output)
        }
        // The stream also ends when this task is cancelled. Only audio that really ended is finished off.
        try Task.checkCancellation()
        let rest = state.frames.drain()
        try await consume(rest, state: &state, context: context, output: output)
        for segment in state.segmenter.flush() {
            try await decode(segment, state: &state, context: context, output: output)
        }
        logSkipped(&state)
    }

    /// Detects speech in `block` (whole frames), feeds the frames to the segmenter, and decodes the segments that
    /// are complete.
    private func consume(
        _ block: [Float], state: inout ListeningState, context: WhisperContext, output: Output
    ) async throws {
        guard !block.isEmpty else { return }
        let probabilities = await speechProbabilities(of: block, state: &state, context: context)
        try Task.checkCancellation()
        var segments: [SpeechSegment] = []
        for (index, probability) in probabilities.enumerated() {
            let start = index * VADSegmenter.frameSamples
            let frame = Array(block[start..<start + VADSegmenter.frameSamples])
            segments += state.segmenter.push(frame: frame, probability: probability)
        }
        for segment in segments {
            try await decode(segment, state: &state, context: context, output: output)
        }
    }

    /// One probability per frame of `block`: from Silero while it works, from the energy detector otherwise.
    private func speechProbabilities(
        of block: [Float], state: inout ListeningState, context: WhisperContext
    ) async -> [Float] {
        if state.usesSileroDetector {
            if let probabilities = await context.speechProbabilities(block) { return probabilities }
            // Nil also comes back once the models are freed, which only happens to a cancelled run.
            if !Task.isCancelled {
                logger.info("The Silero speech detector failed; using the energy detector for the rest of this run")
            }
            state.usesSileroDetector = false
        }
        var probabilities: [Float] = []
        for start in stride(from: 0, to: block.count, by: VADSegmenter.frameSamples) {
            probabilities.append(state.energy.probability(for: Array(block[start..<start + VADSegmenter.frameSamples])))
        }
        return probabilities
    }

    /// Decodes one segment and reports what whisper heard in it, or skips it when the Light model is behind and the
    /// segment is too old.
    private func decode(
        _ segment: SpeechSegment, state: inout ListeningState, context: WhisperContext, output: Output
    ) async throws {
        let audioSeconds = Double(segment.samples.count) / AudioChunk.sampleRate
        // How long ago the segment's audio ended: how far behind the newest chunk is, plus the audio after the segment.
        let end = segment.startSample + Int64(segment.samples.count)
        let age = state.lag + Double(state.received - end) / AudioChunk.sampleRate
        if state.isBehind, size == .light, age > Self.maxSegmentAgeSeconds {
            state.skipped += 1
            return
        }
        logSkipped(&state)

        let options = WhisperOptions(
            language: context.language, prompt: prompt, processorCount: ProcessInfo.processInfo.activeProcessorCount)
        let started = ContinuousClock.now
        let result = await context.transcribe(segment.samples, options: options)
        let finished = ContinuousClock.now
        let processingSeconds = (finished - started).inSeconds

        switch result {
        case .cancelled:
            throw CancellationError()
        case .unloaded:
            try Task.checkCancellation()
            throw SpeechEngineError.engineFailed("The local speech model was unloaded.")
        case .failed(let code):
            try Task.checkCancellation()
            logger.error("whisper.cpp failed to transcribe a segment (code \(code))")
            throw SpeechEngineError.engineFailed("The local speech model failed (code \(code)).")
        case .segments(let parts):
            let behind = state.realTime.record(processingSeconds: processingSeconds, audioSeconds: audioSeconds)
            if behind, !state.isBehind {
                logger.notice(
                    "The local model is falling behind: \(processingSeconds, format: .fixed(precision: 2)) s for \(audioSeconds, format: .fixed(precision: 2)) s of audio"
                )
            }
            // Not only when it starts: the owner's warning goes away by itself unless it keeps hearing about this.
            if state.reports.shouldReport(behind: behind, at: finished) { onFallingBehind() }
            state.isBehind = behind
            if let text = WhisperOutput.text(of: parts) {
                logger.debug("Heard: \(text, privacy: .private)")
                output.yield(TranscriptUpdate(segmentID: "w\(segment.startSample)", text: text, isFinal: true))
            }
        }
    }

    private func logSkipped(_ state: inout ListeningState) {
        let skipped = state.skipped
        guard skipped > 0 else { return }
        logger.info("Skipped \(skipped) segments of old audio to catch up")
        state.skipped = 0
    }
}

// MARK: - The state of one transcription

/// What one transcription keeps between chunks.
private struct ListeningState {
    var frames = FrameBuffer()
    var segmenter = VADSegmenter()
    var energy = EnergyVAD()
    /// False once Silero is not there or has failed: the energy detector takes over.
    var usesSileroDetector: Bool
    var realTime = RealTimeGuard()
    /// What `realTime` said about the latest decode.
    var isBehind = false
    /// When the owner is told about it.
    var reports = FallingBehindReporter()
    var liveLag = LiveLag()
    /// How far behind the live audio the newest chunk was, in seconds.
    var lag = 0.0
    /// How many samples have arrived.
    var received: Int64 = 0
    /// Segments skipped to catch up and not logged yet.
    var skipped = 0
}

/// Collects samples into whole 512-sample frames for the speech detector.
private struct FrameBuffer {
    private var pending: [Float] = []

    /// Adds `samples` and takes out all the whole frames there are now, as one block. The rest waits for more.
    mutating func append(_ samples: [Float]) -> [Float] {
        pending += samples
        let whole = pending.count - pending.count % VADSegmenter.frameSamples
        guard whole > 0 else { return [] }
        let block = Array(pending[..<whole])
        pending.removeFirst(whole)
        return block
    }

    /// What is left, padded with silence to a whole frame. Empty when nothing is left.
    mutating func drain() -> [Float] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }
        return pending + [Float](repeating: 0, count: VADSegmenter.frameSamples - pending.count)
    }
}

// MARK: - Falling behind

/// Decides which decodes tell the engine's owner that the local model is behind.
///
/// The owner takes its warning back after a quiet spell, so a model that stays behind has to keep saying so: the decode
/// that makes it fall behind is reported at once, and so is each later one that is still too slow, but never within
/// `interval` of the last report.
struct FallingBehindReporter: Sendable {
    /// Well inside the owner's quiet spell (two minutes), so that one late report does not let the warning go away.
    static let interval = Duration.seconds(30)

    private var lastReport: ContinuousClock.Instant?

    /// Whether to report the decode that finished at `now`. `behind` is what the `RealTimeGuard` said about it: true
    /// while the model is falling behind, which means this decode was too slow as well.
    mutating func shouldReport(behind: Bool, at now: ContinuousClock.Instant) -> Bool {
        guard behind else { return false }
        if let lastReport, now - lastReport < Self.interval { return false }
        lastReport = now
        return true
    }
}

/// Estimates how far behind the live audio the engine is, so that it can skip old speech when it cannot keep up.
///
/// A capture source delivers numbered chunks of 100 ms, one after another, in real time. A chunk the engine had to
/// wait for is live, and so is one that arrives no later than the chunks before it say it is due: either becomes the
/// reference. A chunk `n` numbers after the reference is due `n × 100 ms` after it, and when the engine only gets to
/// it later, the difference is how far behind it is. A source that drops chunks for a slow consumer still numbers
/// them, so the time they covered counts as passed.
struct LiveLag: Sendable {
    static let chunkSeconds = Double(AudioChunk.samplesPerChunk) / AudioChunk.sampleRate

    private var reference: (sequence: UInt64, time: Double)?

    /// Notes that chunk `sequence` reached the engine at `time` (seconds from any fixed start), after waiting for it
    /// or not, and returns how many seconds behind the live audio that chunk is.
    mutating func update(sequence: UInt64, at time: Double, waited: Bool) -> Double {
        if !waited, let reference, sequence > reference.sequence {
            let due = reference.time + Double(sequence - reference.sequence) * Self.chunkSeconds
            if time > due { return time - due }
        }
        reference = (sequence, time)
        return 0
    }
}

// MARK: - Output

/// Turns what whisper wrote for one segment into the text to report.
enum WhisperOutput {
    /// The pieces' text with the notes about non-speech ("[BLANK_AUDIO]", "(music)", "[Music]", "(silence)" and the
    /// like) taken out, trimmed and joined with single spaces.
    ///
    /// Nil when there is nothing worth reporting: whisper rated every piece as more likely silence than speech (over
    /// silence it tends to repeat its prompt, which is the very names being listened for), or no letter or digit is
    /// left.
    static func text(
        of segments: [WhisperSegment], noSpeechThreshold: Float = WhisperOptions.noSpeechThreshold
    ) -> String? {
        guard segments.contains(where: { $0.noSpeechProbability <= noSpeechThreshold }) else { return nil }
        let text =
            segments
            .map { $0.text.replacing(#/\[[^\]]*\]|\([^)]*\)/#, with: " ") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return text
    }
}

// MARK: - Helpers

extension WhisperModel {
    /// Whether this is one of the English-only whisper models.
    fileprivate var isEnglishOnly: Bool {
        self == .lightEnglish || self == .balancedEnglish
    }
}

extension Duration {
    /// The duration in seconds, with fractions.
    fileprivate var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
