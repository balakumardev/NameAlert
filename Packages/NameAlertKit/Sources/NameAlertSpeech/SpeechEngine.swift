import NameAlertCore

/// How far along an engine is with getting ready: downloading a model, or installing Apple's language assets.
public struct PreparationProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case downloadingModel, installingAppleAssets }

    public let stage: Stage
    /// From 0 (just started) to 1 (done).
    public let fraction: Double

    public init(stage: Stage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Why an engine could not get ready, or stopped listening.
public enum SpeechEngineError: Error, Equatable {
    /// The engine cannot recognize this language.
    case unsupportedLocale(String)
    /// The local model file is not on disk.
    case modelNotInstalled
    /// Apple's language assets are not there and could not be installed.
    case assetsUnavailable
    /// The speech recognition permission was refused.
    case permissionDenied
    case engineFailed(String)
}

/// Turns audio into text as it arrives. The Apple engines and the local whisper model all work this way.
public protocol SpeechEngine: Sendable {
    /// Which recognizer this is. It goes into every hit.
    var id: EngineID { get }

    /// Gets the engine ready for a language: asks for any permission it needs, downloads or installs what is
    /// missing, and loads it. `hints` are the names to listen for. `progress` can be called from any thread.
    func prepare(
        localeIdentifier: String, hints: [String],
        progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws

    /// Recognizes the audio and streams what it hears. Several updates can share one `segmentID`: a later one
    /// replaces an earlier one until the last, which is final.
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, Error>

    /// Changes the names to listen for while the engine is running. Engines apply them where they can.
    func updateHints(_ hints: [String]) async

    /// Stops listening and frees what the engine holds.
    func stop() async
}
