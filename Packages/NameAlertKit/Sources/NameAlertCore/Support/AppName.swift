import Foundation

/// The app's name as people see it, for the text the package shows or sends: the alarm panel, the test alert, the
/// default Telegram message.
///
/// It is the app's `CFBundleDisplayName`, so renaming the app is that one value in its Info.plist. A process without
/// one, such as the test runner, gets "Takeheed".
public enum AppName {
    public static let current = name(displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName"))

    static let fallback = "Takeheed"

    /// `displayName` without the spaces around it, when it is text with something in it; `fallback` otherwise.
    static func name(displayName: Any?) -> String {
        guard let text = (displayName as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return fallback }
        return text
    }
}
