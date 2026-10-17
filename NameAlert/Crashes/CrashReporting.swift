import Foundation
import NameAlertCore

/// The crash report pieces the collector, the prompt and the window share.
extension PendingCrashReportStore {
    /// The store in the app's own folder.
    static var standard: PendingCrashReportStore {
        PendingCrashReportStore(directory: AppPaths.pendingCrashReportsDirectory)
    }
}

extension CrashVersionInfo {
    /// This copy of the app on this Mac: what a crash report names when its own metadata does not.
    static var current: CrashVersionInfo {
        CrashVersionInfo(appVersion: AppInfo.version, build: AppInfo.build, osVersion: Diagnostics.osVersionText)
    }
}

extension CrashReportPreferences {
    /// The app's own preferences.
    static var standard: CrashReportPreferences {
        CrashReportPreferences(defaults: .standard)
    }
}

/// The words of the crash report window and of the Crash Reports setting. Buttons that open something else end in the
/// ellipsis character, as elsewhere in the app.
enum CrashReportCopy {
    static let windowTitle = "Crash Report"
    static var heading: String { "\(AppInfo.displayName) quit unexpectedly last time" }
    static var explanation: String {
        "This report shows where in its code \(AppInfo.displayName) stopped, your app and macOS versions and your Mac model. It never includes what was heard, your keywords, rules or addresses. Nothing is sent: copying it and emailing it is up to you."
    }
    static func waiting(count: Int) -> String? {
        count > 1 ? "\(count) crash reports are waiting. They are in this one report." : nil
    }
    static let noteLabel = "What were you doing? (optional)"
    static let disclosure = "Show the report"
    static let dontAskAgain = "Don't ask again"
    static let dontSend = "Don't Send"
    static let copyAndEmail = "Copy Report & Open Email"
    static let copied = "The report is on your clipboard."
    static let copiedDetail = "Paste it into the email that opened. If no email app opened, write to the support address and paste it there."
    static let close = "Close"
    static let mailSubject = "Takeheed crash report"
    static let tooLong = "Too long. Please shorten it."

    static let settingTitle = "Crash Reports"
    static let settingDetail = "Reports stay on this Mac until you choose to copy and send one."
}
