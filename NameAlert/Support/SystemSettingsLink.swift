import AppKit
import Foundation
import NameAlertCore

/// The System Settings pane where each permission is turned on.
enum SystemSettingsLink {
    static func url(for permission: PermissionKind) -> URL? {
        let address =
            switch permission {
            case .screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .speechRecognition: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            }
        return URL(string: address)
    }

    /// Opens the pane for `permission`.
    @MainActor
    static func open(_ permission: PermissionKind) {
        guard let url = url(for: permission) else { return }
        NSWorkspace.shared.open(url)
    }
}
