import Foundation
import NameAlertCore

/// The app's name, version and build, read from the bundle.
///
/// This is the only place user-facing text gets the app's name from ("Quit \(AppInfo.displayName)"), so renaming the
/// app means changing `CFBundleDisplayName` in the Info.plist and nothing in code.
enum AppInfo {
    /// The name people see: `AppName.current`, the `CFBundleDisplayName` the package's text uses too, so both always
    /// say the same name and only `AppName` holds a fallback.
    static var displayName: String {
        AppName.current
    }

    /// The marketing version, e.g. "1.0.0".
    static var version: String {
        value(for: "CFBundleShortVersionString") ?? "0"
    }

    /// The build number.
    static var build: String {
        value(for: "CFBundleVersion") ?? "0"
    }

    private static func value(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
