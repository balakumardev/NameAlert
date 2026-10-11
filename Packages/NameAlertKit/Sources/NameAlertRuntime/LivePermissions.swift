import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech

/// The system's permissions: the microphone and screen recording through `AudioPermissions`, speech recognition
/// through `SpeechPermission`, notifications through `NotificationActions`.
struct LivePermissions: PermissionsProviding {
    func snapshot() async -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: AudioPermissions.microphoneStatus(),
            screenRecording: AudioPermissions.screenRecordingStatus(),
            speechRecognition: SpeechPermission.status(),
            notifications: await NotificationActions.status())
    }

    func request(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .microphone:
            await AudioPermissions.requestMicrophone()
        case .screenRecording:
            // It may show the system's prompt: ask from the main thread, as for any UI.
            await MainActor.run { AudioPermissions.requestScreenRecording() }
        case .speechRecognition:
            await SpeechPermission.request()
        case .notifications:
            await NotificationActions.requestAuthorization()
        }
    }
}
