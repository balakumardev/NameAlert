import NameAlertCore
import Speech

/// The speech recognition permission, which macOS asks for separately from the microphone.
///
/// The Apple `SFSpeechRecognizer` engine needs it. The app's Info.plist must explain why
/// (`NSSpeechRecognitionUsageDescription`), or macOS ends the app when it asks.
public enum SpeechPermission {
    /// What the user has decided so far. It never shows a prompt.
    public static func status() -> PermissionStatus {
        permissionStatus(for: SFSpeechRecognizer.authorizationStatus())
    }

    /// Shows the system prompt if the user has not decided yet. Returns whether speech recognition is allowed.
    public static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// A restricted Mac (a managed one, for example) cannot allow it, so that counts as denied.
    static func permissionStatus(for status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
