import Foundation

/// What the update check remembers between launches. Checking is on until About turns it off.
public struct UpdateCheckPreferences {
    public static let enabledKey = "updates.enabled"
    public static let lastCheckDateKey = "updates.lastCheckDate"
    public static let skippedVersionKey = "updates.skippedVersion"
    public static let snoozeUntilKey = "updates.snoozeUntil"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether the app checks on its own once a day. True when unset.
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// When the App Store last answered a lookup.
    public var lastCheckDate: Date? {
        get { defaults.object(forKey: Self.lastCheckDateKey) as? Date }
        nonmutating set { store(newValue, forKey: Self.lastCheckDateKey) }
    }

    /// The version the person chose "Skip This Version" for.
    public var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        nonmutating set { store(newValue, forKey: Self.skippedVersionKey) }
    }

    /// No automatic alert before this time ("Remind Me Later").
    public var snoozeUntil: Date? {
        get { defaults.object(forKey: Self.snoozeUntilKey) as? Date }
        nonmutating set { store(newValue, forKey: Self.snoozeUntilKey) }
    }

    private func store(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
