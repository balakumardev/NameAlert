import AppKit
import NameAlertCore

/// What the person chose in the update alert.
enum UpdateAlertChoice: Equatable {
    /// Open Takeheed's page in the Mac App Store.
    case update
    /// Ask again in three days.
    case remindLater
    /// Do not mention this version again.
    case skip
}

/// The alerts of the update check. They only ever link to the Mac App Store: nothing is downloaded or installed here
/// (guideline 2.4.5(vii)).
enum UpdateAlert {

    /// Shows the update alert and waits for an answer. Escape is "Remind Me Later". Call it from a run loop block, not
    /// from inside the main queue's drain (see `UpdateCheckCoordinator.onMainRunLoop`).
    @MainActor
    static func present(_ release: AppStoreRelease, currentVersion: String) -> UpdateAlertChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = UpdateCheckCopy.alertTitle
        alert.informativeText = UpdateCheckCopy.alertMessage(
            release: release, currentVersion: currentVersion,
            notesLimit: UpdateCheckConfiguration.standard.releaseNotesLimit)
        alert.addButton(withTitle: UpdateCheckCopy.updateButton)
        let remindButton = alert.addButton(withTitle: UpdateCheckCopy.remindButton)
        remindButton.keyEquivalent = "\u{1b}"
        remindButton.keyEquivalentModifierMask = []
        alert.addButton(withTitle: UpdateCheckCopy.skipButton)

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .update
        case .alertThirdButtonReturn: return .skip
        default: return .remindLater
        }
    }

    /// Shows the answer of a manual check that is not an available update (that one gets `present`).
    @MainActor
    static func presentManualResult(_ result: ManualCheckResult) {
        guard let words = words(for: result) else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = words.title
        alert.informativeText = words.message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The title and message of a manual result; nil for an available update.
    static func words(for result: ManualCheckResult) -> (title: String, message: String)? {
        switch result {
        case .upToDate(let current):
            (UpdateCheckCopy.upToDateTitle(current: current), UpdateCheckCopy.upToDateMessage)
        case .needsNewerMacOS(let version, let minimum):
            (UpdateCheckCopy.needsNewerMacOSTitle(version: version), UpdateCheckCopy.needsNewerMacOSMessage(minimum: minimum))
        case .failed:
            (UpdateCheckCopy.failedTitle, UpdateCheckCopy.failedMessage)
        case .available:
            nil
        }
    }
}
