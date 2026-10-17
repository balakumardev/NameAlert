import Foundation
import NameAlertCore

/// The words of the update check: exact strings, because App Review sees them. Buttons that open something end in the
/// ellipsis character, as elsewhere in the app.
enum UpdateCheckCopy {
    // The alert
    static var alertTitle: String { "A new version of \(AppInfo.displayName) is available" }
    static let updateButton = "Update"
    static let remindButton = "Remind Me Later"
    static let skipButton = "Skip This Version"

    static func alertMessage(release: AppStoreRelease, currentVersion: String, notesLimit: Int) -> String {
        let summary = "\(AppInfo.displayName) \(release.version) is on the Mac App Store. You have \(currentVersion)."
        guard let notes = release.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else {
            return summary
        }
        return summary + "\n\n" + truncatedNotes(notes, limit: notesLimit)
    }

    /// `notes` cut to at most `limit` characters, at a word, ending in "…".
    static func truncatedNotes(_ notes: String, limit: Int) -> String {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        var head = text.prefix(max(0, limit - 1))
        if !text[head.endIndex].isWhitespace, let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            head = head[..<lastSpace]
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // The answer to a manual check
    static func upToDateTitle(current: String) -> String { "You're up to date (\(current))" }
    static var upToDateMessage: String { "This is the latest version of \(AppInfo.displayName) on the Mac App Store." }
    static func needsNewerMacOSTitle(version: String) -> String { "\(AppInfo.displayName) \(version) needs a newer macOS" }
    static func needsNewerMacOSMessage(minimum: String) -> String {
        "It needs macOS \(minimum) or later. Update macOS in System Settings to get it."
    }
    static let failedTitle = "Couldn't check for updates"
    static let failedMessage = "Check your internet connection and try again."

    // The menu bar window
    static let menuCheck = "Check for Updates…"
    static func menuAvailable(version: String) -> String { "Update Available: \(AppInfo.displayName) \(version)…" }

    // About
    static let aboutToggleTitle = "Check for updates automatically"
    /// Says what is asked and what is not sent, right under the switch.
    static var aboutToggleDetail: String {
        "Once a day, \(AppInfo.displayName) asks Apple's App Store whether a newer version is out. The request names only the app and sends nothing about you or this Mac. It never downloads or installs anything: Update opens the App Store."
    }
    static let aboutCheckButton = "Check for Updates…"

    static func lastChecked(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "Last checked " + formatter.localizedString(for: date, relativeTo: now)
    }
}
