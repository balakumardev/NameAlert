import AVFoundation
import CoreMedia
import Foundation
import NameAlertCore
import Speech
import os

/// Listens with Apple's `SpeechAnalyzer` on macOS 26 and later (spec section 8.3), through `SpeechTranscriber` or,
/// where that does not run (Intel Macs) or lacks the language, `DictationTranscriber`.
///
/// **Getting ready.** `prepare` finds the module's own spelling of the language, installs the language's assets when
/// they are missing (reported as `installingAppleAssets`), and loads the model. Installing reserves the language for
/// the app. Apple lets an app reserve only a few, so when they are all taken, enough of the others are let go first.
/// The speech recognition permission is not needed: on macOS 27 both modules transcribed in a test process whose
/// permission was still undecided, and nothing asked for it.
///
/// **What is reported.** Volatile results as the audio comes in, each replaced in time by a final one, both with up
/// to 3 other readings. A result's segment ID is `sa` and the start of its audio in milliseconds (`sa1080`). A
/// volatile result and the final one for the same audio start at the same time, so they share it. A final result
/// may cover only the first part of what the volatile one did: the rest comes in later results, under their own IDs.
///
/// **Hints.** The names to listen for become the analyzer's contextual strings, set before it starts and again
/// whenever they change.
///
/// **Audio.** Each chunk is converted, as it arrives, to the format the analyzer prefers (16 kHz Int16 on macOS 27).
///
/// **Lifetime.** One analyzer per transcription, because an analyzer that has finished cannot start again. The first
/// is made and loaded by `prepare`, later ones by `transcribe`. When the audio ends, what is left is finalized and the
/// stream finishes. `stop` ends the analysis at once. `transcribe` returns at once and records its run under a lock,
/// as in `WhisperEngine`.
@available(macOS 26, *)
public actor AppleAnalyzerEngine: SpeechEngine {
    /// Which of Apple's speech modules does the work.
    public enum Module: Sendable {
        case speechTranscriber, dictationTranscriber
    }

    public nonisolated let id: EngineID

    private typealias Output = AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation

    /// How many converted chunks (100 ms each) wait for the analyzer: 60 s rides out a slow start for at most ~3.8 MB.
    static let bufferedInputs = 600

    private let module: Module
    private let logger = Log.logger("speechanalyzer")
    /// The module's spelling of the language, from `prepare` until `stop`.
    private var locale: Locale?
    /// The names to listen for.
    private var hints: [String] = []
    /// The analyzer `prepare` made and loaded, until a transcription takes it.
    private var ready: Analysis?
    /// The analyzer of the running transcription, so that new hints reach it.
    private var running: SpeechAnalyzer?
    /// Counts the calls to `prepare` and `stop`. A `prepare` that finds it changed was overtaken by a later call.
    private var generation: UInt64 = 0
    /// The latest `transcribe`, until `stop` or the next `transcribe` ends it.
    private nonisolated let latestRun = OSAllocatedUnfairLock<TranscriptionRun?>(initialState: nil)

    public init(module: Module) {
        self.module = module
        id =
            switch module {
            case .speechTranscriber: .appleSpeechTranscriber
            case .dictationTranscriber: .appleDictationTranscriber
            }
    }

    // MARK: SpeechEngine

    /// Finds the language, installs its assets if they are missing, and loads the model. A running transcription is
    /// ended first. `progress` hears `installingAppleAssets` while assets are installed, and nothing when they are
    /// there already.
    ///
    /// Throws `unsupportedLocale` when the module does not have the language, `assetsUnavailable` when its assets
    /// cannot be installed, `engineFailed` when `SpeechTranscriber` does not run on this Mac or the model does not
    /// load, and `CancellationError` when the calling task was cancelled, or `stop` or another `prepare` came along.
    public func prepare(
        localeIdentifier: String, hints: [String],
        progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        generation &+= 1
        let mine = generation
        await shutDown()

        let supported = try await Self.supportedLocale(for: localeIdentifier, in: module)
        let transcriber = Transcriber(module, locale: supported)
        try await Self.installAssets(
            for: transcriber, locale: supported, localeIdentifier: localeIdentifier, progress: progress,
            logger: logger)
        guard generation == mine, !Task.isCancelled else { throw CancellationError() }
        let analysis = try await Self.load(transcriber, logger: logger)
        guard generation == mine, !Task.isCancelled else {
            await analysis.analyzer.cancelAndFinishNow()
            throw CancellationError()
        }

        locale = supported
        self.hints = hints
        ready = analysis
        logger.info("Ready to transcribe \(supported.identifier(.bcp47), privacy: .public) with \(self.id.rawValue, privacy: .public)")
    }

    /// Transcribes the audio and streams volatile and final results (see the type's notes).
    ///
    /// One transcription runs at a time: a new call ends the stream of the one before. When the audio ends, what is
    /// left is finalized and the stream finishes. When the caller stops listening, the analysis stops. The stream fails
    /// with `engineFailed` when the engine is not prepared or the analyzer fails.
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
                await previous?.finished()  // one transcription at a time
                await self.process(audio, for: run)
            })
        return updates
    }

    /// Replaces the names to listen for, in the running analysis too.
    public func updateHints(_ hints: [String]) async {
        self.hints = hints
        guard let running else { return }
        do {
            try await running.setContext(Self.context(for: hints))
        } catch {
            logger.notice("Could not pass the new names to the analyzer: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the running transcription (its stream finishes), waits for it to return, and lets the analyzer go. Stopping
    /// a stopped engine does nothing.
    public func stop() async {
        generation &+= 1
        await shutDown()
    }

    // MARK: Running

    /// Ends the latest transcription, waits for it to return, and lets go of an analyzer that was never used.
    private func shutDown() async {
        let run = latestRun.withLock { latest in
            defer { latest = nil }
            return latest
        }
        run?.end()  // cancels its task, which cancels the analysis
        let unused = ready
        ready = nil
        locale = nil
        await run?.finished()
        await unused?.analyzer.cancelAndFinishNow()
    }

    /// The work of one `transcribe`: takes or makes an analyzer, gives it the hints, and runs the analysis.
    private func process(_ audio: AsyncStream<AudioChunk>, for run: TranscriptionRun) async {
        guard !Task.isCancelled else {
            run.output.finish()
            return
        }
        guard let locale else {
            run.output.finish(throwing: SpeechEngineError.engineFailed("Apple speech recognition is not ready."))
            return
        }
        let analysis: Analysis
        if let ready {
            analysis = ready
            self.ready = nil
        } else {
            do {
                analysis = try await Self.load(Transcriber(module, locale: locale), logger: logger)
            } catch {
                if let error = error as? SpeechEngineError {
                    run.output.finish(throwing: error)
                } else {
                    run.output.finish()  // cancelled
                }
                return
            }
        }

        running = analysis.analyzer
        defer { running = nil }
        do {
            try await analysis.analyzer.setContext(Self.context(for: hints))
        } catch {
            logger.notice("Could not pass the names to the analyzer: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try await Self.analyze(audio, with: analysis, into: run.output, logger: logger)
            run.output.finish()
        } catch {
            // Only this task being cancelled is a normal end. An analysis cancelled by something else is a failure.
            if Task.isCancelled {
                run.output.finish()
            } else if let error = error as? SpeechEngineError {
                run.output.finish(throwing: error)
            } else {
                logger.error("Apple's speech analyzer failed: \(error.localizedDescription, privacy: .public)")
                run.output.finish(throwing: SpeechEngineError.engineFailed("Apple speech recognition stopped working."))
            }
        }
    }

    /// Runs one analysis: the audio goes in, converted, while the results come out as updates. Returns once the audio
    /// has ended and everything is final; throws the first error.
    ///
    /// Results that end while the audio is still coming mean the analyzer stopped by itself. That is an error too:
    /// otherwise the audio would go on into an analyzer that hears nothing, and the stream would never say so.
    private static func analyze(
        _ audio: AsyncStream<AudioChunk>, with analysis: Analysis, into output: Output, logger: Logger
    ) async throws {
        // About 60 s of audio waits for an analyzer that starts slowly or falls behind; older chunks are dropped, so
        // that memory stays bounded, as it does on the way in.
        let (inputs, input) = AsyncStream.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(bufferedInputs))
        do {
            try await analysis.analyzer.start(inputSequence: inputs)
        } catch {
            input.finish()
            throw error
        }
        // Set once all the audio is in, before the analyzer is asked to finalize. The results may end before that
        // request returns.
        let audioEnded = OSAllocatedUnfairLock(initialState: false)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await feed(audio, into: input, analysis: analysis, audioEnded: audioEnded, logger: logger)
                return false
            }
            group.addTask {
                try await report(analysis.transcriber, into: output)
                return true
            }
            do {
                while let resultsEnded = try await group.next() {
                    if resultsEnded, !audioEnded.withLock({ $0 }), !Task.isCancelled {
                        logger.error("Apple's speech analyzer stopped while the audio was still coming")
                        throw SpeechEngineError.engineFailed("Apple speech recognition stopped.")
                    }
                }
            } catch {
                group.cancelAll()
                input.finish()
                await analysis.analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }

    /// Converts the chunks and hands them to the analyzer. When the audio ends, has the analyzer finalize what it has
    /// and finish; when the task is cancelled, has it stop at once.
    private static func feed(
        _ audio: AsyncStream<AudioChunk>, into input: AsyncStream<AnalyzerInput>.Continuation, analysis: Analysis,
        audioEnded: OSAllocatedUnfairLock<Bool>, logger: Logger
    ) async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [analysis.transcriber.module])
        guard let converter = AnalyzerAudio(analyzerFormat: format) else {
            input.finish()
            throw SpeechEngineError.engineFailed("The audio could not be converted for Apple's speech analyzer.")
        }
        var failedChunks = 0
        for await chunk in audio {
            if let buffer = converter.convert(chunk.samples) {
                input.yield(AnalyzerInput(buffer: buffer))
            } else {
                failedChunks += 1
                if failedChunks == 1 { logger.error("A chunk of audio could not be converted for the analyzer") }
            }
        }
        input.finish()
        if Task.isCancelled {
            await analysis.analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        audioEnded.withLock { $0 = true }
        try await analysis.analyzer.finalizeAndFinishThroughEndOfInput()
    }

    /// Passes the module's results on as updates, until they end.
    private static func report(_ transcriber: Transcriber, into output: Output) async throws {
        switch transcriber {
        case .speech(let module): try await report(module.results, into: output)
        case .dictation(let module): try await report(module.results, into: output)
        }
    }

    private static func report<Results: AsyncSequence>(
        _ results: Results, into output: Output
    ) async throws where Results.Element: AnalyzerResult {
        for try await result in results {
            if let update = AnalyzerTranscript.update(for: result) { output.yield(update) }
        }
    }

    // MARK: Getting ready

    /// The module's own spelling of the language. Throws `unsupportedLocale` when it does not have it.
    private static func supportedLocale(for identifier: String, in module: Module) async throws -> Locale {
        let requested = Locale(identifier: identifier)
        let supported: Locale?
        switch module {
        case .speechTranscriber:
            guard SpeechTranscriber.isAvailable else {
                throw SpeechEngineError.engineFailed("Apple's speech transcriber doesn't run on this Mac.")
            }
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        case .dictationTranscriber:
            supported = await DictationTranscriber.supportedLocale(equivalentTo: requested)
        }
        guard let supported else { throw SpeechEngineError.unsupportedLocale(identifier) }
        return supported
    }

    /// Installs the assets the transcriber needs, unless they are there. Either way the language ends up reserved
    /// for the app.
    private static func installAssets(
        for transcriber: Transcriber, locale: Locale, localeIdentifier: String,
        progress: @escaping @Sendable (PreparationProgress) -> Void, logger: Logger
    ) async throws {
        let modules = [transcriber.module]
        if await AssetInventory.status(forModules: modules) == .unsupported {
            throw SpeechEngineError.unsupportedLocale(localeIdentifier)
        }
        await makeRoomToReserve(locale, logger: logger)

        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        } catch {
            logger.error("Could not ask for Apple's speech assets: \(error.localizedDescription, privacy: .public)")
            throw SpeechEngineError.assetsUnavailable
        }
        guard let request else { return }  // installed already

        logger.info("Installing Apple's speech assets for \(locale.identifier(.bcp47), privacy: .public)")
        let reporter = AssetProgress(report: progress)
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
            @Sendable observed, _ in reporter.update(observed.fractionCompleted)
        }
        defer { observation.invalidate() }
        do {
            try await request.downloadAndInstall()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            logger.error("Could not install Apple's speech assets: \(error.localizedDescription, privacy: .public)")
            throw SpeechEngineError.assetsUnavailable
        }
        reporter.complete()
        logger.info("Installed Apple's speech assets for \(locale.identifier(.bcp47), privacy: .public)")
    }

    /// When the app has reserved as many languages as Apple allows and `locale` is not one of them, lets go of enough
    /// of the others for installing `locale` to reserve it. The app listens in one language at a time.
    private static func makeRoomToReserve(_ locale: Locale, logger: Logger) async {
        let reserved = await AssetInventory.reservedLocales
        let wanted = locale.identifier(.bcp47)
        let limit = AssetInventory.maximumReservedLocales
        guard reserved.count >= limit, !reserved.contains(where: { $0.identifier(.bcp47) == wanted }) else { return }
        for other in reserved.prefix(reserved.count - limit + 1) {
            await AssetInventory.release(reservedLocale: other)
            logger.info(
                "Released \(other.identifier(.bcp47), privacy: .public) to make room for \(wanted, privacy: .public)")
        }
    }

    /// A new analyzer for `transcriber`, with its model loaded.
    private static func load(_ transcriber: Transcriber, logger: Logger) async throws -> Analysis {
        let modules = [transcriber.module]
        let analyzer = SpeechAnalyzer(
            modules: modules, options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            logger.error("Could not load Apple's speech model: \(error.localizedDescription, privacy: .public)")
            throw SpeechEngineError.engineFailed("Apple's speech model could not be loaded.")
        }
        return Analysis(transcriber: transcriber, analyzer: analyzer)
    }

    /// The names to listen for, as an analysis context.
    private static func context(for hints: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(hints.prefix(100))
        return context
    }
}

// MARK: - The module and its analyzer

/// The module that does the work, with its own result type.
@available(macOS 26, *)
enum Transcriber: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    /// A new module for `locale`, reporting volatile results, alternatives and the audio time of what it heard.
    ///
    /// Each module also needs one more option to work on live audio, measured on macOS 27 with speech fed in real
    /// time and followed by silence. Without `fastResults`, `SpeechTranscriber` held back every result until the
    /// sentence was over: the first, for a name 0.3 s in, came 4.2 s after the audio started; with it, 1.1 s.
    /// Without `frequentFinalization`, `DictationTranscriber` streamed volatile results but made none final, even
    /// after 6 s of silence, so one volatile segment would grow for as long as it listened; with it, the results were
    /// final 1.9 s after the speech ended.
    init(_ kind: AppleAnalyzerEngine.Module, locale: Locale) {
        switch kind {
        case .speechTranscriber:
            self = .speech(
                SpeechTranscriber(
                    locale: locale, transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
                    attributeOptions: [.audioTimeRange]))
        case .dictationTranscriber:
            self = .dictation(
                DictationTranscriber(
                    locale: locale, contentHints: [], transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .alternativeTranscriptions, .frequentFinalization],
                    attributeOptions: [.audioTimeRange]))
        }
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let module): module
        case .dictation(let module): module
        }
    }
}

/// A transcriber and the analyzer that runs it, for one transcription.
@available(macOS 26, *)
struct Analysis: Sendable {
    let transcriber: Transcriber
    let analyzer: SpeechAnalyzer
}

/// What the results of `SpeechTranscriber` and `DictationTranscriber` have in common.
@available(macOS 26, *)
protocol AnalyzerResult: SpeechModuleResult {
    var text: AttributedString { get }
    var alternatives: [AttributedString] { get }
}

@available(macOS 26, *)
extension SpeechTranscriber.Result: AnalyzerResult {}

@available(macOS 26, *)
extension DictationTranscriber.Result: AnalyzerResult {}

// MARK: - Results and audio

/// Turns an analyzer's results into transcript updates.
enum AnalyzerTranscript {
    @available(macOS 26, *)
    static func update(for result: some AnalyzerResult) -> TranscriptUpdate? {
        update(
            text: String(result.text.characters), alternatives: result.alternatives.map { String($0.characters) },
            start: result.range.start, isFinal: result.isFinal)
    }

    /// The update for a result whose audio starts at `start`. Nil for a volatile result with nothing in it.
    static func update(text: String, alternatives: [String], start: CMTime, isFinal: Bool) -> TranscriptUpdate? {
        let text = Readings.text(text)
        guard !text.isEmpty || isFinal else { return nil }
        return TranscriptUpdate(
            segmentID: segmentID(start: start), text: text,
            alternatives: Readings.alternatives(alternatives, besides: text), isFinal: isFinal)
    }

    /// `sa` and `start` in whole milliseconds, cut rather than rounded; `sa0` for a time that is not a number.
    static func segmentID(start: CMTime) -> String {
        guard start.isNumeric else { return "sa0" }
        return "sa\(start.convertScale(1_000, method: .roundTowardZero).value)"
    }
}

/// Converts the app's audio (16 kHz mono Float32 samples) to the format an analyzer wants, chunk by chunk.
///
/// One `AVAudioConverter` is kept for the whole transcription, so that a resampler keeps its history from one chunk to
/// the next. Only one task uses it.
final class AnalyzerAudio {
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    /// Nil when the analyzer takes the app's format as it is.
    private let converter: AVAudioConverter?

    /// Nil when there is no converter between the formats. Without an `analyzerFormat` the audio goes as it is.
    init?(analyzerFormat: AVAudioFormat?) {
        guard let source = MonoAudio.makeFormat() else { return nil }
        sourceFormat = source
        guard let analyzerFormat, analyzerFormat != source else {
            targetFormat = source
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: source, to: analyzerFormat) else { return nil }
        targetFormat = analyzerFormat
        self.converter = converter
    }

    /// `samples` in the analyzer's format. Nil when there are none, or the conversion failed.
    func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let input = MonoAudio.buffer(samples, format: sourceFormat) else { return nil }
        guard let converter else { return input }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        // `.noDataNow` once the chunk is used up, not `.endOfStream`: the converter keeps its state for the next one.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Passes the progress of an asset installation on, at most once for each whole percent and in order, then 1 at the
/// end. The installation reports from any thread.
private final class AssetProgress: Sendable {
    private let report: @Sendable (PreparationProgress) -> Void
    /// The last whole percent passed on.
    private let lastPercent = OSAllocatedUnfairLock(initialState: -1)

    init(report: @escaping @Sendable (PreparationProgress) -> Void) {
        self.report = report
    }

    func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let percent = Int(min(max(fraction, 0), 0.99) * 100)  // 100 % is said by `complete`, once it is installed
        lastPercent.withLock { last in
            guard percent > last else { return }
            last = percent
            report(PreparationProgress(stage: .installingAppleAssets, fraction: Double(percent) / 100))
        }
    }

    func complete() {
        lastPercent.withLock { last in
            last = 100
            report(PreparationProgress(stage: .installingAppleAssets, fraction: 1))
        }
    }
}
