import AppKit

/// Loops a system sound and shows a modal dialog that the user must dismiss
/// to silence it. Unlike `BeepAlert`/`NotificationAlert`, this channel keeps
/// pinging until the user acknowledges. Designed for the "I really need to
/// know my name was said" use case.
///
/// While the dialog is up, additional hits are suppressed (a single
/// presentation is enough — no stacked dialogs, no overlapping sounds).
struct PersistentAlert: Alert {
    let id = "persistent"
    let displayName = "Persistent Alert (until dismissed)"
    let soundName: String

    func fire(reason: Hit) async {
        await MainActor.run {
            PersistentAlertPresenter.shared.present(reason: reason,
                                                    soundName: soundName)
        }
    }
}

/// Owns the singleton state so multiple `PersistentAlert` instances (e.g. from
/// a settings reload) all coordinate through the same "is a dialog up?" flag
/// and share one looping `NSSound`.
@MainActor
final class PersistentAlertPresenter {
    static let shared = PersistentAlertPresenter()

    private var sound: NSSound?
    private var isShowing = false

    private init() {}

    func present(reason: Hit, soundName: String) {
        guard !isShowing else { return }
        isShowing = true
        defer {
            sound?.stop()
            sound = nil
            isShowing = false
        }

        let s = NSSound(named: NSSound.Name(soundName))
        s?.loops = true
        s?.play()
        sound = s

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Heard \"\(reason.keyword)\""
        alert.informativeText = reason.matchedText.isEmpty
            ? "Tap Dismiss to silence."
            : reason.matchedText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Dismiss")
        _ = alert.runModal()
    }
}
