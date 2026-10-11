import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech

extension RuntimeDependencies {
    /// Stand-ins that never capture, recognize, download or send anything, for SwiftUI previews and screenshots.
    ///
    /// Every permission is granted, Apple's `SpeechTranscriber` is there for English, and every model is installed.
    /// Capture starts but never delivers audio, so a controller that is asked to start stays in
    /// `.preparing(.starting)`. There are no alert channels and no calls. The configuration and the history live in a
    /// new temporary folder, which is created only if something is saved.
    public static func inert() -> RuntimeDependencies {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlert-inert-\(UUID().uuidString)", isDirectory: true)
        return RuntimeDependencies(
            configStore: ConfigStore(fileURL: folder.appendingPathComponent("config.json")),
            historyStore: HistoryStore(fileURL: folder.appendingPathComponent("history.json")),
            secrets: InMemorySecretStore(),
            permissions: InertPermissions(),
            capabilities: {
                EngineCapabilities(
                    osMajorVersion: 26, speechTranscriberAvailable: true, speechTranscriberLocales: ["en-US"],
                    dictationTranscriberLocales: ["en-US"], sfSpeechOnDeviceLocales: ["en-US"], isAppleSilicon: true)
            },
            makeSource: { _ in InertSource() },
            makeEngine: { InertEngine(id: $0) },
            models: InertModels(),
            callStates: { AsyncStream { _ in } },  // no call ever starts
            callDetectionSupported: true,
            channels: [],
            systemLocaleIdentifier: { "en-US" },
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            backoffBase: .seconds(1))
    }
}

private struct InertPermissions: PermissionsProviding {
    func snapshot() async -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .granted)
    }

    func request(_ kind: PermissionKind) async -> Bool { true }
}

/// Starts, stays silent, and stops when asked.
private actor InertSource: AudioCaptureSource {
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var reason: CaptureEndReason?

    func start() async throws -> AsyncStream<AudioChunk> {
        await stop()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        reason = nil
        return stream
    }

    func stop() async {
        guard let continuation else { return }
        self.continuation = nil
        reason = .stopped  // before the stream ends, as the protocol promises
        continuation.finish()
    }

    func endReason() async -> CaptureEndReason? { reason }
}

/// Ready at once; hears nothing, and finishes when its audio does.
private struct InertEngine: SpeechEngine {
    let id: EngineID

    func prepare(
        localeIdentifier: String, hints: [String], progress: @escaping @Sendable (PreparationProgress) -> Void
    ) async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        AsyncThrowingStream { output in
            let draining = Task {
                for await _ in audio {}
                output.finish()
            }
            output.onTermination = { _ in draining.cancel() }
        }
    }

    func updateHints(_ hints: [String]) async {}

    func stop() async {}
}

private struct InertModels: ModelProviding {
    func isInstalled(_ model: WhisperModel) async -> Bool { true }

    func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

    func delete(_ model: WhisperModel) async throws {}
}
