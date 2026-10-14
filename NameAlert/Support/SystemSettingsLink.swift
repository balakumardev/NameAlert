import AppKit
import Foundation
import NameAlertAudio
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

    /// Opens the pane for `permission`, asking the system first when `asksFirst(_:)` says so.
    @MainActor
    static func open(_ permission: PermissionKind) {
        if asksFirst(permission) { _ = AudioPermissions.requestScreenRecording() }
        guard let url = url(for: permission) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether opening the pane asks the system for the permission first. The Screen Recording pane lists only the apps
    /// that asked: when macOS has no answer on record (the app was taken out of the list, or `tccutil` reset it),
    /// asking puts it back there and shows the system's prompt. When a "no" is on record, asking does nothing.
    static func asksFirst(_ permission: PermissionKind) -> Bool {
        permission == .screenRecording
    }
}
