import AVFoundation
import CoreGraphics
import NameAlertCore

/// The permissions audio capture needs: the microphone, and screen recording for system audio.
public enum AudioPermissions {
    public static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Shows the system's microphone prompt if the user has not decided yet. Returns whether access is granted.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// `.granted` or `.notDetermined`: macOS does not tell an app whether screen recording was denied or never asked.
    public static func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    /// Shows the system's screen recording prompt the first time; after that it only reports the current state.
    /// ScreenCaptureKit may only see a new grant after Takeheed relaunches.
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
