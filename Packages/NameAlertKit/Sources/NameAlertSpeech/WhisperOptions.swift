import Foundation
import whisper

/// How whisper.cpp decodes one stretch of speech (spec section 8.5).
///
/// Everything here is plain values, worked out before any call into the library, so it can be tested without a model:
/// - Greedy decoding with a single candidate, at temperature 0 and with no fallback to higher temperatures. The
///   result is the same for the same audio, and a hard stretch costs one decode, never six.
/// - No text carried over from earlier audio (`no_context`): every segment stands alone, so a name heard once is not
///   repeated into the next segment. No timestamps, which this app has no use for.
/// - Blank output and the tokens that are not speech (symbols such as brackets and music notes) are suppressed.
/// - The no-speech threshold is 0.6; the engine also drops a whole segment above it (see `WhisperOutput`).
/// - Only as much of the encoder as the audio needs (`audioContext`), and a few threads (`threads`).
/// - The language is the locale's language; the prompt is the names to listen for, so whisper spells them that way.
struct WhisperOptions: Sendable, Equatable {
    /// Greedy decoding keeps one candidate.
    static let bestOf = 1
    /// Above this no-speech probability whisper's text is not trusted.
    static let noSpeechThreshold: Float = 0.6
    /// The longest prompt, in characters. whisper uses at most 224 prompt tokens; names are a few tokens each.
    static let maxPromptLength = 200

    /// whisper.cpp's code for the spoken language, such as "en" or "de".
    var language: String
    /// The names to listen for, comma separated, as whisper's initial prompt. Nil when there are none.
    var prompt: String?
    /// How many encoder positions to run (each covers 20 ms of audio).
    var audioContext: Int
    /// How many CPU threads whisper may use.
    var threads: Int

    /// The settings for decoding `audioSeconds` of audio on a Mac with `processorCount` active processors.
    init(language: String, prompt: String?, audioSeconds: Double, processorCount: Int) {
        self.language = language
        self.prompt = prompt
        self.audioContext = Self.audioContext(seconds: audioSeconds)
        self.threads = Self.threads(processorCount: processorCount)
    }

    /// Enough encoder positions for the audio (50 a second) and 64 more as a margin, at least 256 and at most the
    /// model's 1 500 (30 s). Running fewer than 1 500 makes short segments several times faster to encode.
    static func audioContext(seconds: Double) -> Int {
        let needed = Int((max(0, seconds) * 50).rounded(.up)) + 64
        return min(1_500, max(256, needed))
    }

    /// Up to 4 threads, leaving two processors for the rest of the Mac, and always at least one.
    static func threads(processorCount: Int) -> Int {
        min(4, max(1, processorCount - 2))
    }

    /// The language part of a locale identifier, lowercased: what comes before the first "-", "_" or "@" ("en-US"
    /// is "en", "pt_BR" is "pt"). An English-only model is always given "en".
    static func language(localeIdentifier: String, englishOnlyModel: Bool) -> String {
        if englishOnlyModel { return "en" }
        return localeIdentifier.prefix { $0 != "-" && $0 != "_" && $0 != "@" }.lowercased()
    }

    /// The names joined with ", ", as many whole names from the start as fit in `maxPromptLength` characters. Blank
    /// names are skipped. Nil when no name fits.
    static func prompt(hints: [String]) -> String? {
        var prompt = ""
        for hint in hints {
            let name = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let longer = prompt.isEmpty ? name : prompt + ", " + name
            guard longer.count <= maxPromptLength else { break }
            prompt = longer
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// Writes these settings into whisper.cpp's parameters. The language and the prompt are not set here: they are
    /// C strings that have to stay alive while the decode runs, so `WhisperContext` sets them around the call.
    func apply(to params: inout whisper_full_params) {
        params.strategy = WHISPER_SAMPLING_GREEDY
        params.greedy.best_of = Int32(Self.bestOf)
        params.n_threads = Int32(threads)
        params.audio_ctx = Int32(audioContext)

        params.translate = false
        params.detect_language = false
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = false
        params.token_timestamps = false

        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false

        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0
        params.no_speech_thold = Self.noSpeechThreshold

        // The engine finds the speech itself, frame by frame, so whisper's own VAD stays off.
        params.vad = false
    }
}
