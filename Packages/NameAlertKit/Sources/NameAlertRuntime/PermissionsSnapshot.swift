import NameAlertCore

/// The state of every permission Takeheed uses, at one moment.
public struct PermissionsSnapshot: Equatable, Sendable {
    public var microphone: PermissionStatus
    public var screenRecording: PermissionStatus
    public var speechRecognition: PermissionStatus
    public var notifications: PermissionStatus

    public init(
        microphone: PermissionStatus, screenRecording: PermissionStatus,
        speechRecognition: PermissionStatus, notifications: PermissionStatus
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
        self.speechRecognition = speechRecognition
        self.notifications = notifications
    }

    /// The status of one permission.
    public subscript(kind: PermissionKind) -> PermissionStatus {
        get {
            switch kind {
            case .microphone: microphone
            case .screenRecording: screenRecording
            case .speechRecognition: speechRecognition
            case .notifications: notifications
            }
        }
        set {
            switch kind {
            case .microphone: microphone = newValue
            case .screenRecording: screenRecording = newValue
            case .speechRecognition: speechRecognition = newValue
            case .notifications: notifications = newValue
            }
        }
    }

    /// Nothing known yet: what the controller shows before it has looked.
    static let undetermined = PermissionsSnapshot(
        microphone: .notDetermined, screenRecording: .notDetermined, speechRecognition: .notDetermined,
        notifications: .notDetermined)
}

/// Reads and asks for the permissions. The app's is `LivePermissions`; tests use their own.
public protocol PermissionsProviding: Sendable {
    /// The current state of every permission. Never shows a prompt.
    func snapshot() async -> PermissionsSnapshot
    /// Asks for one permission, showing the system prompt if the user has not decided yet. Returns whether it is
    /// granted.
    func request(_ kind: PermissionKind) async -> Bool
}
