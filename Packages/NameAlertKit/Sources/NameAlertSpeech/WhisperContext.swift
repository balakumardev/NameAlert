import Foundation
import NameAlertCore
import os
import whisper

/// One piece of text whisper.cpp produced for a stretch of audio, and how likely it rated the audio to hold no speech.
struct WhisperSegment: Sendable, Equatable {
    let text: String
    let noSpeechProbability: Float
}

/// What came of decoding one stretch of audio.
enum WhisperInference: Sendable, Equatable {
    /// whisper's text, in order. Empty when it found nothing to write.
    case segments([WhisperSegment])
    /// The calling task was cancelled, and the decode was stopped or never started.
    case cancelled
    /// `whisper_full` failed with this return code.
    case failed(Int32)
    /// The models had been freed.
    case unloaded
}

/// The whisper.cpp model and the Silero speech detector, loaded from their files and used from one serial queue.
///
/// A whisper.cpp context must not be used from two threads at once, and a decode can keep a CPU busy for a second.
/// So every call into the library, the frees included, runs on `queue`, one after the other, and the async methods
/// wait for their turn with a continuation: no thread of Swift's cooperative pool ever blocks on whisper. The two
/// pointers are only read and written on the queue. `release` frees them there and sets them to nil, after which
/// every call does nothing, so a call that arrives after the engine stopped is harmless.
///
/// The detector keeps its state from one call to the next (`whisper_vad_detect_speech_no_reset`), so it can be given
/// audio a few frames at a time, as the audio arrives. It must get whole 512-sample frames: the library pads a partial
/// frame with zeros, and the padding would become part of what the detector remembers.
final class WhisperContext: @unchecked Sendable {
    /// Why a model could not be loaded.
    enum LoadError: Error, Equatable {
        /// whisper.cpp could not load the model file.
        case modelUnusable
        /// The model cannot decode this language.
        case unsupportedLanguage
    }

    static let queueLabel = "dev.balakumar.namealert.whisper"

    /// The language every decode uses, such as "en".
    let language: String
    /// Whether the Silero detector loaded. Without it `speechProbabilities` returns nil.
    let hasSpeechDetector: Bool

    private let queue: DispatchQueue
    /// The whisper model. Only touched on `queue`.
    private var model: OpaquePointer?
    /// The Silero detector. Only touched on `queue`.
    private var detector: OpaquePointer?

    /// Loads the whisper model, and the detector when `speechDetectorModel` is given, on a new serial queue.
    ///
    /// Throws when the whisper model does not load or does not know `language`. The detector is optional: when it
    /// does not load, the context works without it (`hasSpeechDetector` is false).
    static func load(model: URL, speechDetectorModel: URL?, language: String) async throws -> WhisperContext {
        WhisperLog.install()
        let queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result {
                        try WhisperContext(
                            queue: queue, model: model, speechDetectorModel: speechDetectorModel, language: language)
                    })
            }
        }
    }

    /// Runs on `queue`. Everything that can fail happens before the first stored property is set.
    private init(queue: DispatchQueue, model modelFile: URL, speechDetectorModel: URL?, language: String) throws {
        dispatchPrecondition(condition: .onQueue(queue))

        var modelParams = whisper_context_default_params()
        #if arch(arm64)
            modelParams.use_gpu = true  // Metal, on Apple silicon only
        #else
            modelParams.use_gpu = false
        #endif
        let loaded = modelFile.withUnsafeFileSystemRepresentation { path -> OpaquePointer? in
            guard let path else { return nil }
            return whisper_init_from_file_with_params(path, modelParams)
        }
        guard let model = loaded else { throw LoadError.modelUnusable }
        guard Self.decodes(language, with: model) else {
            whisper_free(model)
            throw LoadError.unsupportedLanguage
        }

        var detector: OpaquePointer?
        if let speechDetectorModel {
            var detectorParams = whisper_vad_default_context_params()
            detectorParams.n_threads = 1  // a few frames at a time: more threads would cost more than they save
            detectorParams.use_gpu = false
            detector = speechDetectorModel.withUnsafeFileSystemRepresentation { path -> OpaquePointer? in
                guard let path else { return nil }
                return whisper_vad_init_from_file_with_params(path, detectorParams)
            }
        }

        self.queue = queue
        self.model = model
        self.detector = detector
        self.language = language
        self.hasSpeechDetector = detector != nil
    }

    deinit {
        // `release` frees the models on the queue. This is the backstop for a context dropped without it. A context
        // is only deinitialized once nothing holds it any more, queued work included, so nothing can be using the
        // pointers now.
        if let detector { whisper_vad_free(detector) }
        if let model { whisper_free(model) }
    }

    // MARK: Calls

    /// Makes the detector forget the audio it has seen, for a new stream.
    func resetSpeechDetector() async {
        await onQueue { $0.resetDetectorOnQueue() }
    }

    /// The speech probability (0 to 1) of each 512-sample frame of `samples`, which must hold whole frames. Nil when
    /// there is no detector, it was freed, or it failed.
    func speechProbabilities(_ samples: [Float]) async -> [Float]? {
        await onQueue { $0.detectSpeechOnQueue(samples) }
    }

    /// Decodes `samples`, 16 kHz mono. Cancelling the calling task stops the decode between two of its steps.
    func transcribe(_ samples: [Float], options: WhisperOptions) async -> WhisperInference {
        let abort = AbortFlag()
        return await withTaskCancellationHandler {
            await onQueue { $0.decodeOnQueue(samples, options: options, abort: abort) }
        } onCancel: {
            abort.raise()
        }
    }

    /// Frees both models, after any call still in the queue. Every later call does nothing, this one included.
    func release() async {
        await onQueue { $0.freeOnQueue() }
    }

    // MARK: On the queue

    /// Runs `work` on the queue and waits for it without blocking a thread.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable (WhisperContext) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(self)) }
        }
    }

    private func resetDetectorOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let detector { whisper_vad_reset_state(detector) }
    }

    private func detectSpeechOnQueue(_ samples: [Float]) -> [Float]? {
        dispatchPrecondition(condition: .onQueue(queue))
        let frames = samples.count / VADSegmenter.frameSamples
        guard let detector, frames > 0, samples.count == frames * VADSegmenter.frameSamples else { return nil }
        let detected = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(detector, buffer.baseAddress, Int32(buffer.count))
        }
        // The Silero model's window is 512 samples, so there is one probability per frame. Anything else is unusable.
        guard detected, whisper_vad_n_probs(detector) == Int32(frames), let probabilities = whisper_vad_probs(detector)
        else { return nil }
        return Array(UnsafeBufferPointer(start: probabilities, count: frames))
    }

    private func decodeOnQueue(_ samples: [Float], options: WhisperOptions, abort: AbortFlag) -> WhisperInference {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let model else { return .unloaded }
        guard !abort.isRaised else { return .cancelled }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        options.apply(to: &params)
        // whisper.cpp reads the language and the prompt while it decodes: these copies live until it returns.
        guard let language = strdup(options.language) else { return .failed(-1) }
        defer { free(language) }
        let prompt = options.prompt.flatMap { strdup($0) }
        defer { free(prompt) }
        params.language = UnsafePointer(language)
        params.initial_prompt = prompt.map { UnsafePointer($0) }
        // Checked by whisper.cpp after encoding and after each decoder step. `abort` outlives the call: the caller
        // holds it.
        params.abort_callback = { flag in
            guard let flag else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(flag).takeUnretainedValue().isRaised
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(model, params, buffer.baseAddress, Int32(buffer.count))
        }
        if abort.isRaised { return .cancelled }
        guard status == 0 else { return .failed(status) }

        let count = max(0, whisper_full_n_segments(model))
        return .segments(
            (0..<count).map { index in
                WhisperSegment(
                    text: whisper_full_get_segment_text(model, index).map { String(cString: $0) } ?? "",
                    noSpeechProbability: whisper_full_get_segment_no_speech_prob(model, index))
            })
    }

    private func freeOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        if let detector {
            whisper_vad_free(detector)
            self.detector = nil
        }
        if let model {
            whisper_free(model)
            self.model = nil
        }
    }

    /// Whether `model` can decode `language`. An English-only model knows only "en". A multilingual one knows the
    /// languages it has a token for: whisper.cpp's list also has languages that only newer models know, and asking an
    /// older model for one of those would give it a token that means something else.
    private static func decodes(_ language: String, with model: OpaquePointer) -> Bool {
        guard whisper_is_multilingual(model) != 0 else { return language == "en" }
        let id = whisper_lang_id(language)
        return id >= 0 && whisper_token_lang(model, id) < whisper_token_translate(model)
    }
}

/// Asks a running decode to stop. Raised from any thread; read by whisper.cpp on the thread that decodes.
final class AbortFlag: Sendable {
    private let raised = OSAllocatedUnfairLock(initialState: false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() {
        raised.withLock { $0 = true }
    }
}

/// Sends whisper.cpp's and ggml's log to the unified log.
///
/// Left alone, the library prints to stderr: a dozen lines for every model load and four for every call to the
/// detector. Its warnings and errors go to the log; everything else is dropped. They hold no audio and no text, but
/// some name the model's full path, which has the user's name in it, so they are private (the engine logs its own
/// public line for every failure). The hook is process-wide, so it is set once, before the first model loads.
enum WhisperLog {
    private static let logger = Log.logger("whisper")

    private static let installed: Void = {
        whisper_log_set(
            { level, text, _ in
                guard let text else { return }
                let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                switch level {
                case GGML_LOG_LEVEL_ERROR: WhisperLog.logger.error("whisper.cpp: \(message, privacy: .private)")
                case GGML_LOG_LEVEL_WARN: WhisperLog.logger.notice("whisper.cpp: \(message, privacy: .private)")
                default: break
                }
            }, nil)
    }()

    static func install() {
        _ = installed
    }
}
