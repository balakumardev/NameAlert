import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech

/// How parts of the app that the controller did not make reach it: the alarm panel's Snooze button and the local
/// model's warning that it is falling behind. The app sets `controller` right after making the controller; until then,
/// and after it is gone, both do nothing.
@MainActor
public final class ControllerBox {
    public static let shared = ControllerBox()

    public weak var controller: ListeningController?

    init() {}

    func snooze(minutes: Int) async {
        await controller?.snooze(minutes: minutes)
    }

    func noteLocalModelFallingBehind() {
        controller?.noteLocalModelFallingBehind()
    }
}

extension RuntimeDependencies {
    /// The real parts: the files in Application Support, the Keychain, the system's permissions, capture through
    /// ScreenCaptureKit and the microphone, Apple's speech engines and whisper, the call detector and every alert
    /// channel. Making them starts nothing: a source captures, an engine loads and a channel sends only when the
    /// controller asks.
    ///
    /// One `ModelManager` serves both the model downloads and the whisper engines, because it shares a download
    /// between the callers that want the same model only among its own callers. What this Mac's speech recognition
    /// can do is looked at once, the first time it is needed.
    public static func live(appVersion: String, build: String) -> RuntimeDependencies {
        let models = ModelManager()
        let capabilities = CapabilitiesProbe()
        let calls = CallDetector()
        let fallingBehind: @Sendable () -> Void = {
            Task { @MainActor in ControllerBox.shared.noteLocalModelFallingBehind() }
        }
        return RuntimeDependencies(
            configStore: ConfigStore(),
            historyStore: HistoryStore(),
            secrets: KeychainSecretStore(),
            permissions: LivePermissions(),
            capabilities: { await capabilities.value() },
            makeSource: { AudioCaptureFactory.make($0) },
            makeEngine: { SpeechEngineFactory.make($0, modelManager: models, onFallingBehind: fallingBehind) },
            models: models,
            callStates: { calls.states() },
            callDetectionSupported: CallDetector.isSupported,
            channels: AlertChannelFactory.makeAll(appVersion: appVersion, build: build) { minutes in
                await ControllerBox.shared.snooze(minutes: minutes)
            },
            systemLocaleIdentifier: { Locale.current.identifier },
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            backoffBase: .seconds(1))
    }
}

/// Asks this Mac what its speech recognition can do the first time, and gives the same answer after that.
private actor CapabilitiesProbe {
    private var probe: Task<EngineCapabilities, Never>?

    func value() async -> EngineCapabilities {
        if let probe { return await probe.value }
        let probe = Task { await EngineResolver.probeCapabilities() }
        self.probe = probe
        return await probe.value
    }
}
