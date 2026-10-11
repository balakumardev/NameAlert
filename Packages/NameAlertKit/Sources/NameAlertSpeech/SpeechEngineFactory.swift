import NameAlertCore

/// Makes the speech engine an `EngineID` names.
public enum SpeechEngineFactory {
    /// The engine for `id`. SpeechAnalyzer's two engines need macOS 26: before that, `id` gets an engine that fails
    /// with "Requires macOS 26" (the resolver never picks them there). `onFallingBehind` goes to the whisper engines,
    /// which call it when they cannot keep up with the audio.
    public static func make(
        _ id: EngineID, modelManager: ModelManager, onFallingBehind: @escaping @Sendable () -> Void
    ) -> any SpeechEngine {
        switch id {
        case .appleSpeechTranscriber:
            if #available(macOS 26, *) { return AppleAnalyzerEngine(module: .speechTranscriber) }
            return FailingEngine(id: id, error: .engineFailed("Requires macOS 26"))
        case .appleDictationTranscriber:
            if #available(macOS 26, *) { return AppleAnalyzerEngine(module: .dictationTranscriber) }
            return FailingEngine(id: id, error: .engineFailed("Requires macOS 26"))
        case .appleSFSpeech:
            return AppleSFSpeechEngine()
        case .whisperLight:
            return WhisperEngine(size: .light, modelManager: modelManager, onFallingBehind: onFallingBehind)
        case .whisperBalanced:
            return WhisperEngine(size: .balanced, modelManager: modelManager, onFallingBehind: onFallingBehind)
        }
    }
}

/// An engine that cannot run on this Mac: everything it is asked to do fails with the same error.
struct FailingEngine: SpeechEngine {
    let id: EngineID
    let error: SpeechEngineError

    func prepare(
        localeIdentifier: String, hints: [String],
        progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {
        throw error
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }

    func updateHints(_ hints: [String]) async {}

    func stop() async {}
}
