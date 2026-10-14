import AppKit
import NameAlertCore
import NameAlertRuntime
import Observation

/// Which permissions NameAlert has already asked the system for, kept across launches.
///
/// macOS never says whether Screen Recording was refused, and it does not ask again about notifications it asked about
/// once: after a request, "not allowed" can only mean "turn it on in System Settings". So for those two a fix that offers
/// to ask ("Allow…") offers it once, and from then on points to System Settings (`PermissionKind.promptsOnce`). Setup
/// (the permission cards), Settings and the menu bar popover share this.
@MainActor
@Observable
final class PermissionAsks {
    /// What the app uses. Tests make their own, on a defaults suite of their own.
    static let shared = PermissionAsks()

    @ObservationIgnored private let defaults: UserDefaults
    private var asked: Set<PermissionKind>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        asked = Set(PermissionKind.allCases.filter { defaults.bool(forKey: Self.key($0)) })
    }

    static func key(_ kind: PermissionKind) -> String {
        "permission.asked.\(kind.rawValue)"
    }

    func hasAsked(_ kind: PermissionKind) -> Bool {
        asked.contains(kind)
    }

    func markAsked(_ kind: PermissionKind) {
        guard asked.insert(kind).inserted else { return }
        defaults.set(true, forKey: Self.key(kind))
    }
}

extension ListeningController {
    /// Asks the system for a permission (it shows its own prompt when the user has not decided yet), then remembers that
    /// it was asked, so that the next fix points to System Settings. Answering the prompt leaves another app in front,
    /// so the window that asked comes forward again. Returns whether the permission is granted.
    @discardableResult
    func ask(for kind: PermissionKind, asks: PermissionAsks = .shared) async -> Bool {
        let window = NSApp.keyWindow
        let granted = await requestPermission(kind)
        asks.markAsked(kind)
        if Foreground.raisesAfterAsking(for: kind), let window, window.isVisible {
            Foreground.bring(window)
        }
        return granted
    }
}

/// What to offer for a permission: ask for it, or send the user to System Settings.
enum PermissionOffer: Equatable, Sendable {
    /// Ask: the system shows its prompt.
    case allow
    /// The system will not ask again (or did, and the answer was no): the user changes it in System Settings.
    case openSystemSettings
    /// Nothing: it is allowed.
    case none

    /// `hasAsked` is whether the app asked the system for `kind` before, in this setup or an earlier run.
    init(kind: PermissionKind, status: PermissionStatus, hasAsked: Bool) {
        switch status {
        case .granted: self = .none
        case .denied: self = .openSystemSettings
        case .notDetermined: self = hasAsked && kind.promptsOnce ? .openSystemSettings : .allow
        }
    }
}

extension PermissionKind {
    /// What the permission is called, here and in System Settings.
    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .speechRecognition: "Speech Recognition"
        case .notifications: "Notifications"
        }
    }

    /// Whether the system shows its prompt only the first time the app asks. Screen Recording's request says nothing
    /// about a "no", and a notifications request that was asked once is not asked again: after one request, "not
    /// decided" means the user turns it on in System Settings. The microphone and speech recognition prompts come back
    /// whenever macOS has no answer on record (it never had one, or it was reset with `tccutil`): asking shows them.
    var promptsOnce: Bool {
        switch self {
        case .screenRecording, .notifications: true
        case .microphone, .speechRecognition: false
        }
    }
}
