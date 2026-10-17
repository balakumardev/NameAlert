import Foundation

/// What Apple's public lookup says about the newest Takeheed on the Mac App Store.
public struct AppStoreRelease: Equatable, Sendable {
    public let version: String
    /// "14.0": the oldest macOS this version runs on.
    public let minimumOSVersion: String?
    /// When this version went on sale. A brand new release is not announced for a day.
    public let releaseDate: Date?
    public let releaseNotes: String?
    public let storeURL: URL?

    public init(
        version: String, minimumOSVersion: String?, releaseDate: Date?, releaseNotes: String?, storeURL: URL?
    ) {
        self.version = version
        self.minimumOSVersion = minimumOSVersion
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.storeURL = storeURL
    }
}

/// The update check's timings and limits, all in one place.
public struct UpdateCheckConfiguration: Sendable, Equatable {
    /// The first check, this long after launch, so it never competes with start-up.
    public var firstCheckDelay: TimeInterval = 20
    /// Then once a day, plus up to `maxJitter` so installs do not all ask in the same minute.
    public var interval: TimeInterval = 86_400
    public var maxJitter: TimeInterval = 3_600
    /// A release is announced a day after it goes on sale, so a build that Apple pulls, or a store page that is not
    /// ready yet, does not send people to the App Store for nothing.
    public var minimumReleaseAge: TimeInterval = 86_400
    /// "Remind Me Later" holds the alert back for three days.
    public var snoozeDuration: TimeInterval = 259_200
    public var requestTimeout: TimeInterval = 15
    public var releaseNotesLimit: Int = 600

    public static let standard = UpdateCheckConfiguration()

    public init() {}
}

/// The answer to a manual "Check for Updates…".
public enum ManualCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case available(AppStoreRelease)
    case needsNewerMacOS(version: String, minimum: String)
    case failed
}

/// Who is told about a release. Versions compare numerically (`AppVersion`).
public enum UpdateEligibility {

    /// A newer release that runs on this Mac, has been on sale long enough and is not the one the person skipped. It
    /// is what the menu row offers. A release without a readable minimum macOS or a release date is held back: it
    /// cannot be checked.
    public static func isOffered(
        _ release: AppStoreRelease,
        currentVersion: String,
        osVersion: OperatingSystemVersion,
        now: Date,
        skippedVersion: String?,
        configuration: UpdateCheckConfiguration = .standard
    ) -> Bool {
        guard AppVersion.isNewer(release.version, than: currentVersion) else { return false }
        guard runsOnThisMac(release, osVersion: osVersion) == true else { return false }
        guard let releaseDate = release.releaseDate,
            now.timeIntervalSince(releaseDate) >= configuration.minimumReleaseAge
        else { return false }
        return release.version != skippedVersion
    }

    /// Whether the automatic alert may show: offered, and not snoozed.
    public static func shouldAlert(
        _ release: AppStoreRelease,
        currentVersion: String,
        osVersion: OperatingSystemVersion,
        now: Date,
        skippedVersion: String?,
        snoozeUntil: Date?,
        configuration: UpdateCheckConfiguration = .standard
    ) -> Bool {
        guard
            isOffered(
                release, currentVersion: currentVersion, osVersion: osVersion, now: now,
                skippedVersion: skippedVersion, configuration: configuration)
        else { return false }
        return snoozeUntil.map { now >= $0 } ?? true
    }

    /// What a manual check says. It ignores the release's age, a skipped version and the snooze: the person asked. A
    /// newer release whose minimum macOS cannot be read counts as available, since its store page says what the Mac
    /// needs.
    public static func manualResult(
        _ release: AppStoreRelease?,
        currentVersion: String,
        osVersion: OperatingSystemVersion
    ) -> ManualCheckResult {
        guard let release else { return .failed }
        guard AppVersion.isNewer(release.version, than: currentVersion) else {
            return .upToDate(current: currentVersion)
        }
        if runsOnThisMac(release, osVersion: osVersion) == false, let minimum = release.minimumOSVersion {
            return .needsNewerMacOS(version: release.version, minimum: minimum)
        }
        return .available(release)
    }

    /// Nil when the release does not say, or says something that is not a version.
    private static func runsOnThisMac(_ release: AppStoreRelease, osVersion: OperatingSystemVersion) -> Bool? {
        guard let text = release.minimumOSVersion, let minimum = AppVersion(text) else { return nil }
        return minimum <= AppVersion(osVersion)
    }
}

public enum UpdateCheckSchedule {
    /// How long to wait after a check: the interval plus `random` (0...1) of the jitter. A `random` outside 0...1 is
    /// pulled into it.
    public static func nextDelay(_ configuration: UpdateCheckConfiguration, random: Double) -> TimeInterval {
        configuration.interval + min(max(random, 0), 1) * configuration.maxJitter
    }
}

/// Whether this run checks for updates at all: the Mac App Store build only (the disk image build and a build from
/// source never ask), or a Debug run that forces it.
public enum UpdateCheckAvailability {
    public static func isAvailable(appStoreBuild: Bool, debugForce: Bool) -> Bool {
        appStoreBuild || debugForce
    }
}
