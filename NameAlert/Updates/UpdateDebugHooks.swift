import Foundation
import NameAlertCore

/// Whether this run checks for updates, and the Debug-only launch arguments for trying the check without a store:
/// - `-UpdateCheckForceEnabled YES` turns the check on in a Debug run (the scheme lists it, unticked).
/// - `-UpdateCheckFakeLatestVersion 9.9.9` makes a Debug run see that version in the store, on sale for two days.
/// A Release build ignores both.
enum UpdateDebugHooks {
    /// The Mac App Store build checks; so does a Debug run that forces it.
    static var isAvailable: Bool {
        UpdateCheckAvailability.isAvailable(appStoreBuild: StoreBuild.isAppStoreBuild, debugForce: debugForce)
    }

    static var debugForce: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "UpdateCheckForceEnabled")
        #else
        return false
        #endif
    }

    static func fakeRelease(defaults: UserDefaults = .standard, now: Date = Date()) -> AppStoreRelease? {
        #if DEBUG
        guard let version = defaults.string(forKey: "UpdateCheckFakeLatestVersion"), !version.isEmpty else { return nil }
        return AppStoreRelease(
            version: version, minimumOSVersion: "14.0", releaseDate: now.addingTimeInterval(-2 * 86_400),
            releaseNotes: "Debug fake release (-UpdateCheckFakeLatestVersion)", storeURL: nil)
        #else
        return nil
        #endif
    }
}
