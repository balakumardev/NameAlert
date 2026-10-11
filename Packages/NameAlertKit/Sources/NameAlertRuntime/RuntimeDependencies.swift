import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech

/// Everything `ListeningController` works with, so that tests and previews can give it stand-ins.
///
/// `live(appVersion:build:)` is what the app uses; `inert()` is for previews and screenshots: nothing in it ever
/// captures, recognizes or sends anything.
public struct RuntimeDependencies: Sendable {
    public var configStore: ConfigStore
    public var historyStore: HistoryStore
    public var secrets: any SecretStore
    public var permissions: any PermissionsProviding
    /// What this Mac's speech recognition can do. The engine is picked from it each time listening starts.
    public var capabilities: @Sendable () async -> EngineCapabilities
    /// A new, stopped capture source for a kind of audio. Called once for each attempt to listen.
    public var makeSource: @Sendable (AudioSourceKind) -> any AudioCaptureSource
    /// A new speech engine. Called once for each attempt to listen.
    public var makeEngine: @Sendable (EngineID) -> any SpeechEngine
    public var models: any ModelProviding
    /// A new subscription to the call state ("Only during calls" mode). Ends when its consumer stops listening.
    public var callStates: @Sendable () -> AsyncStream<CallState>
    /// Whether this Mac can tell when a call is going on. Without it, "Only during calls" listens all the time.
    public var callDetectionSupported: Bool
    public var channels: [any AlertChannel]
    /// The system's language, used when the settings do not name one.
    public var systemLocaleIdentifier: @Sendable () -> String
    public var now: @Sendable () -> Date
    /// Waits for a while: the snooze, the pause after waking, the pause before retrying.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// The pause before the first retry after a failure. It doubles with each failure in a row, up to 30 times this.
    public var backoffBase: Duration

    public init(
        configStore: ConfigStore,
        historyStore: HistoryStore,
        secrets: any SecretStore,
        permissions: any PermissionsProviding,
        capabilities: @escaping @Sendable () async -> EngineCapabilities,
        makeSource: @escaping @Sendable (AudioSourceKind) -> any AudioCaptureSource,
        makeEngine: @escaping @Sendable (EngineID) -> any SpeechEngine,
        models: any ModelProviding,
        callStates: @escaping @Sendable () -> AsyncStream<CallState>,
        callDetectionSupported: Bool,
        channels: [any AlertChannel],
        systemLocaleIdentifier: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        backoffBase: Duration
    ) {
        self.configStore = configStore
        self.historyStore = historyStore
        self.secrets = secrets
        self.permissions = permissions
        self.capabilities = capabilities
        self.makeSource = makeSource
        self.makeEngine = makeEngine
        self.models = models
        self.callStates = callStates
        self.callDetectionSupported = callDetectionSupported
        self.channels = channels
        self.systemLocaleIdentifier = systemLocaleIdentifier
        self.now = now
        self.sleep = sleep
        self.backoffBase = backoffBase
    }
}
