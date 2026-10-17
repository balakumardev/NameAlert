import Foundation
import NameAlertCore
import Testing

/// Who gets told about a release, and when: the rules behind the automatic alert, the menu row and the manual
/// "Check for Updates…" answer.
@Suite("Update eligibility")
struct UpdateEligibilityTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)
    private let os = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
    private let configuration = UpdateCheckConfiguration.standard

    private func release(
        version: String = "1.0.2", minimumOS: String? = "14.0", age: TimeInterval? = 2 * 86_400
    ) -> AppStoreRelease {
        AppStoreRelease(
            version: version, minimumOSVersion: minimumOS, releaseDate: age.map { now.addingTimeInterval(-$0) },
            releaseNotes: nil, storeURL: nil)
    }

    private func isOffered(_ r: AppStoreRelease, current: String = "1.0.1", skipped: String? = nil) -> Bool {
        UpdateEligibility.isOffered(
            r, currentVersion: current, osVersion: os, now: now, skippedVersion: skipped, configuration: configuration)
    }

    private func shouldAlert(
        _ r: AppStoreRelease, current: String = "1.0.1", skipped: String? = nil, snoozeUntil: Date? = nil
    ) -> Bool {
        UpdateEligibility.shouldAlert(
            r, currentVersion: current, osVersion: os, now: now, skippedVersion: skipped, snoozeUntil: snoozeUntil,
            configuration: configuration)
    }

    @Test func offeredAndAlertWhenEverythingHolds() {
        #expect(isOffered(release()))
        #expect(shouldAlert(release()))
    }

    @Test func nothingNotNewerIsOffered() {
        #expect(!isOffered(release(version: "1.0.1")), "equal")
        #expect(!isOffered(release(version: "1.0.0")), "older")
        #expect(!isOffered(release(version: "1.0.1"), current: "1.0.1.0"), "equal with a zero tail")
        #expect(!isOffered(release(version: "2.0-beta"), current: "1.0"), "unreadable")
        #expect(!shouldAlert(release(version: "1.0.1")))
    }

    @Test func versionsCompareAsNumbers() {
        #expect(isOffered(release(version: "1.10"), current: "1.9"), "1.10 is newer than 1.9")
        #expect(!isOffered(release(version: "1.9"), current: "1.10"))
        #expect(isOffered(release(version: "1.0.10"), current: "1.0.9"))
        #expect(isOffered(release(version: "2"), current: "1.9.9"))
    }

    @Test func aReleaseMustBeADayOld() {
        #expect(!isOffered(release(age: 86_399)), "young releases are held back")
        #expect(!shouldAlert(release(age: 86_399)))
        #expect(isOffered(release(age: 86_400)))
        #expect(shouldAlert(release(age: 86_400)))
        #expect(!isOffered(release(age: nil)), "no date, no offer")
    }

    @Test func theMacMustRunTheRelease() {
        #expect(!isOffered(release(minimumOS: "15.7")), "needs a newer macOS")
        #expect(!isOffered(release(minimumOS: "16.0")))
        #expect(isOffered(release(minimumOS: "15.6.1")), "equal to this Mac")
        #expect(!isOffered(release(minimumOS: "15.10")), "15.10 is newer than 15.6")
        #expect(!isOffered(release(minimumOS: nil)))
        #expect(!isOffered(release(minimumOS: "fifteen")))
    }

    @Test func aSkippedVersionIsHiddenUntilANewerOne() {
        #expect(!isOffered(release(version: "1.0.2"), skipped: "1.0.2"))
        #expect(!shouldAlert(release(version: "1.0.2"), skipped: "1.0.2"))
        #expect(isOffered(release(version: "1.0.3"), skipped: "1.0.2"), "a newer release is offered again")
        #expect(isOffered(release(version: "1.0.2"), skipped: "1.0.1"))
    }

    @Test func snoozeHoldsBackTheAlertButNotTheMenuRow() {
        let r = release()
        #expect(isOffered(r))
        #expect(!shouldAlert(r, snoozeUntil: now.addingTimeInterval(1)))
        #expect(shouldAlert(r, snoozeUntil: now))
        #expect(shouldAlert(r, snoozeUntil: now.addingTimeInterval(-1)))
    }

    // MARK: Manual check

    private func manual(_ r: AppStoreRelease?, current: String = "1.0.1") -> ManualCheckResult {
        UpdateEligibility.manualResult(r, currentVersion: current, osVersion: os)
    }

    @Test func manualResultWhenTheLookupFailed() {
        #expect(manual(nil) == .failed)
    }

    @Test func manualResultUpToDate() {
        #expect(manual(release(version: "1.0.1")) == .upToDate(current: "1.0.1"))
        #expect(manual(release(version: "1.0.2"), current: "1.0.3") == .upToDate(current: "1.0.3"))
    }

    @Test func manualResultNeedsANewerMac() {
        #expect(manual(release(minimumOS: "99.0")) == .needsNewerMacOS(version: "1.0.2", minimum: "99.0"))
    }

    @Test func manualCheckIgnoresAgeSkipAndSnooze() {
        let young = release(age: 3_600)
        #expect(manual(young) == .available(young))
        let noDate = release(age: nil)
        #expect(manual(noDate) == .available(noDate))
        let unreadableOS = release(minimumOS: nil)
        #expect(manual(unreadableOS) == .available(unreadableOS), "the store page says what the Mac needs")
    }

    // MARK: Schedule and configuration

    @Test func nextDelayIsADayPlusUpToAnHourOfJitter() {
        #expect(UpdateCheckSchedule.nextDelay(.standard, random: 0) == 86_400)
        #expect(UpdateCheckSchedule.nextDelay(.standard, random: 1) == 90_000)
        #expect(UpdateCheckSchedule.nextDelay(.standard, random: 0.5) == 88_200)
        #expect(UpdateCheckSchedule.nextDelay(.standard, random: -5) == 86_400, "pulled into range")
        #expect(UpdateCheckSchedule.nextDelay(.standard, random: 9) == 90_000, "pulled into range")
    }

    @Test func jitterStaysInBoundsForManyDraws() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let delay = UpdateCheckSchedule.nextDelay(.standard, random: Double.random(in: 0...1, using: &generator))
            #expect(delay >= 86_400 && delay <= 90_000)
        }
    }

    @Test func standardConfigurationMatchesTheSpec() {
        let c = UpdateCheckConfiguration.standard
        #expect(c.firstCheckDelay == 20)
        #expect(c.interval == 86_400)
        #expect(c.maxJitter == 3_600)
        #expect(c.minimumReleaseAge == 86_400)
        #expect(c.snoozeDuration == 259_200)
        #expect(c.requestTimeout == 15)
        #expect(c.releaseNotesLimit == 600)
    }

    @Test func theCheckRunsOnlyInAnAppStoreBuildUnlessDebugForcesIt() {
        #expect(UpdateCheckAvailability.isAvailable(appStoreBuild: true, debugForce: false))
        #expect(!UpdateCheckAvailability.isAvailable(appStoreBuild: false, debugForce: false))
        #expect(UpdateCheckAvailability.isAvailable(appStoreBuild: false, debugForce: true))
    }
}

@Suite("App version")
struct AppVersionTests {
    @Test func readsDottedNumbers() {
        #expect(AppVersion("1.0.2")?.components == [1, 0, 2])
        #expect(AppVersion("7")?.components == [7])
    }

    @Test func rejectsWhatIsNotANumberedVersion() {
        for text in ["", ".", "1..2", "1.0.", ".1", "1.0.1b", "2.0-beta", "v1.0", "1.0 ", "-1"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func aMissingComponentCountsAsZero() {
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
        #expect(AppVersion("1.10")! > AppVersion("1.9")!)
    }

    @Test func comparesTheMacsVersion() {
        let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        #expect(AppVersion("14.0")! <= AppVersion(os))
        #expect(AppVersion("14.0.1")! > AppVersion(os))
    }

    @Test func isNewerIsFalseWhenEitherSideCannotBeRead() {
        #expect(!AppVersion.isNewer("x", than: "1.0"))
        #expect(!AppVersion.isNewer("2.0", than: "x"))
        #expect(AppVersion.isNewer("2.0", than: "1.9.9"))
    }
}

@Suite("Update preferences")
struct UpdatePreferencesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dev.balakumar.namealert.tests.updates.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func checkingIsOnWhenNothingIsStored() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UpdateCheckPreferences(defaults: defaults)
        #expect(preferences.isEnabled)
        #expect(preferences.lastCheckDate == nil)
        #expect(preferences.skippedVersion == nil)
        #expect(preferences.snoozeUntil == nil)
    }

    @Test func eachPreferenceRoundTripsUnderItsPrefixedKey() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UpdateCheckPreferences(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_792_000_000)

        preferences.isEnabled = false
        preferences.lastCheckDate = date
        preferences.skippedVersion = "1.0.2"
        preferences.snoozeUntil = date.addingTimeInterval(259_200)

        // A second instance over the same defaults sees the same values: they survive a relaunch.
        let again = UpdateCheckPreferences(defaults: defaults)
        #expect(!again.isEnabled)
        #expect(again.lastCheckDate == date)
        #expect(again.skippedVersion == "1.0.2")
        #expect(again.snoozeUntil == date.addingTimeInterval(259_200))

        #expect(defaults.object(forKey: "updates.enabled") as? Bool == false)
        #expect(defaults.object(forKey: "updates.lastCheckDate") as? Date == date)
        #expect(defaults.object(forKey: "updates.skippedVersion") as? String == "1.0.2")
        #expect(defaults.object(forKey: "updates.snoozeUntil") as? Date == date.addingTimeInterval(259_200))
    }

    @Test func settingNilForgetsAValue() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UpdateCheckPreferences(defaults: defaults)
        preferences.skippedVersion = "1.0.2"
        preferences.snoozeUntil = Date()
        preferences.skippedVersion = nil
        preferences.snoozeUntil = nil
        #expect(defaults.object(forKey: "updates.skippedVersion") == nil)
        #expect(defaults.object(forKey: "updates.snoozeUntil") == nil)
    }
}
