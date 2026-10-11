import Foundation
import NameAlertCore

/// What the controller is doing while it gets ready to listen.
public enum PreparationStage: Equatable, Sendable {
    /// Checking the permissions and picking the speech engine.
    case permissions
    /// Downloading the local speech model, from 0 to 1.
    case downloadingModel(Double)
    /// Installing Apple's speech files for the language, from 0 to 1.
    case installingAppleAssets(Double)
    /// Loading the speech engine and starting audio capture.
    case starting
}

/// What is listening: the speech engine, the audio source and the language.
public struct ListeningInfo: Equatable, Sendable {
    public let engine: EngineID
    public let source: AudioSourceKind
    /// The language, spelled the way the engine lists it.
    public let localeIdentifier: String

    public init(engine: EngineID, source: AudioSourceKind, localeIdentifier: String) {
        self.engine = engine
        self.source = source
        self.localeIdentifier = localeIdentifier
    }
}

/// Why the controller is not listening when it should be.
public enum ListeningIssue: Equatable, Sendable {
    /// A permission the listening needs is not granted. Not retried: fixed by the user, and checked again when the
    /// permissions are refreshed.
    case permissionDenied(PermissionKind)
    /// No speech engine can do what the settings ask for. The text says why, for the user.
    case engineUnavailable(String)
    /// The local speech model is not on disk and could not be downloaded, or was deleted while it downloaded.
    case modelMissing
    /// Audio capture failed. Retried after a pause that grows with each failure.
    case captureFailed(String)
    /// The speech engine failed. Retried like a capture failure.
    case engineFailed(String)
}

/// What the controller is doing.
public enum ListeningState: Equatable, Sendable {
    /// Paused by the user, or not started.
    case off
    case preparing(PreparationStage)
    case listening(ListeningInfo)
    /// "Only during calls" and no call is going on: capture and the engine are stopped.
    case waitingForCall
    /// Capture and the engine are stopped until `until`, then listening starts again.
    case snoozed(until: Date)
    case error(ListeningIssue)
}

/// Something the user should know while listening goes on.
public enum RuntimeWarning: Equatable, Sendable, Hashable {
    /// The local model cannot keep up with the audio on this Mac: the Light model would.
    case localModelFallingBehind
    /// Screen recording is allowed, but capture was refused: ScreenCaptureKit only sees the permission after
    /// NameAlert relaunches.
    case screenRecordingNeedsRelaunch
}
