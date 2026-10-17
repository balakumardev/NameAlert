import Foundation
import NameAlertCore
import NameAlertRuntime
import Testing

@testable import ScreenshotHost

private let start = Date(timeIntervalSince1970: 1_792_000_000)
private let day: TimeInterval = 86_400

private func release(
    version: String = "1.0.2", age: TimeInterval = 2 * day, minimumOS: String? = "14.0", notes: String? = "• A welcome guide."
) -> AppStoreRelease {
    AppStoreRelease(
        version: version, minimumOSVersion: minimumOS, releaseDate: start.addingTimeInterval(-age), releaseNotes: notes,
        storeURL: nil)
}

@Suite("Update check words")
struct UpdateCheckCopyTests {
    @Test("The alert and its three buttons")
    func alertStrings() {
        #expect(UpdateCheckCopy.alertTitle == "A new version of \(AppInfo.displayName) is available")
        #expect(UpdateCheckCopy.updateButton == "Update")
        #expect(UpdateCheckCopy.remindButton == "Remind Me Later")
        #expect(UpdateCheckCopy.skipButton == "Skip This Version")
    }

    @Test("Each manual answer has its own words")
    func manualResultStrings() throws {
        #expect(UpdateCheckCopy.upToDateTitle(current: "1.0.1") == "You're up to date (1.0.1)")
        #expect(UpdateCheckCopy.upToDateMessage == "This is the latest version of \(AppInfo.displayName) on the Mac App Store.")
        #expect(UpdateCheckCopy.needsNewerMacOSTitle(version: "1.0.2") == "\(AppInfo.displayName) 1.0.2 needs a newer macOS")
        #expect(UpdateCheckCopy.needsNewerMacOSMessage(minimum: "16.0") == "It needs macOS 16.0 or later. Update macOS in System Settings to get it.")
        #expect(UpdateCheckCopy.failedTitle == "Couldn't check for updates")
        #expect(UpdateCheckCopy.failedMessage == "Check your internet connection and try again.")
        #expect(UpdateAlert.words(for: .upToDate(current: "1.0.1"))?.title == "You're up to date (1.0.1)")
        #expect(UpdateAlert.words(for: .failed)?.title == "Couldn't check for updates")
        #expect(UpdateAlert.words(for: .needsNewerMacOS(version: "2.0", minimum: "99.0"))?.message.contains("99.0") == true)
        #expect(UpdateAlert.words(for: .available(release())) == nil, "an available update gets the alert instead")
    }

    @Test("The menu bar window rows")
    func menuStrings() {
        #expect(UpdateCheckCopy.menuCheck == "Check for Updates…")
        #expect(UpdateCheckCopy.menuAvailable(version: "1.0.2") == "Update Available: \(AppInfo.displayName) 1.0.2…")
        #expect(UpdateCheckCopy.menuAvailable(version: "1.0.2").hasPrefix("Update Available: "))
    }

    @Test("About names the switch and says what is asked and what is not sent")
    func aboutStrings() {
        #expect(UpdateCheckCopy.aboutToggleTitle == "Check for updates automatically")
        let detail = UpdateCheckCopy.aboutToggleDetail
        #expect(detail.contains("Once a day"))
        #expect(detail.contains("Apple's App Store"))
        #expect(detail.contains("nothing about you or this Mac"))
        #expect(detail.contains("never downloads or installs anything"))
    }

    @Test("Long notes are cut at a word, with an ellipsis, and never inside one")
    func notes() {
        let long = String(repeating: "word ", count: 300)
        let cut = UpdateCheckCopy.truncatedNotes(long, limit: 600)
        #expect(cut.count <= 600)
        #expect(cut.hasSuffix("word…"))
        #expect(UpdateCheckCopy.truncatedNotes("alpha beta gamma delta epsilon", limit: 14) == "alpha beta…")
        #expect(UpdateCheckCopy.truncatedNotes("• A welcome guide.", limit: 600) == "• A welcome guide.")
        let exact = String(repeating: "a", count: 600)
        #expect(UpdateCheckCopy.truncatedNotes(exact, limit: 600) == exact)
    }

    @Test("The alert message names both versions and adds the notes when there are some")
    func alertMessage() {
        let summary = "\(AppInfo.displayName) 1.0.2 is on the Mac App Store. You have 1.0.1."
        #expect(UpdateCheckCopy.alertMessage(release: release(notes: nil), currentVersion: "1.0.1", notesLimit: 600) == summary)
        #expect(UpdateCheckCopy.alertMessage(release: release(notes: "  \n "), currentVersion: "1.0.1", notesLimit: 600) == summary)
        #expect(UpdateCheckCopy.alertMessage(release: release(), currentVersion: "1.0.1", notesLimit: 600) == summary + "\n\n• A welcome guide.")
    }

    @Test("Last checked")
    func lastChecked() {
        #expect(UpdateCheckCopy.lastChecked(nil, now: start) == "Not checked yet")
        let text = UpdateCheckCopy.lastChecked(start.addingTimeInterval(-2 * day), now: start)
        #expect(text.hasPrefix("Last checked "))
    }
}

@Suite("Update check timing and gating")
@MainActor
struct UpdateCheckGateTests {
    @Test("An automatic alert waits while listening is starting or going on")
    func busyStates() {
        #expect(UpdateCheckCoordinator.isBusy(.preparing(.permissions)) == true)
        #expect(UpdateCheckCoordinator.isBusy(.off) == false)
        #expect(UpdateCheckCoordinator.isBusy(.waitingForCall) == false)
        #expect(UpdateCheckCoordinator.isBusy(.snoozed(until: start)) == false)
    }

    @Test("Only the App Store build, compiled in, is available; a Debug run can force it")
    func availability() {
        #expect(StoreBuild.isAppStoreBuild == false, "this test build is not the App Store build")
        #expect(UpdateCheckAvailability.isAvailable(appStoreBuild: StoreBuild.isAppStoreBuild, debugForce: false) == false)
        #expect(UpdateCheckCoordinator.unavailable().isAvailable == false)
    }

    @Test("The Debug fake release is the version asked for, two days old, and nothing without the argument")
    func fakeRelease() throws {
        let name = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(UpdateDebugHooks.fakeRelease(defaults: defaults) == nil)
        defaults.set("9.9.9", forKey: "UpdateCheckFakeLatestVersion")
        let fake = try #require(UpdateDebugHooks.fakeRelease(defaults: defaults, now: start))
        #expect(fake.version == "9.9.9")
        #expect(UpdateEligibility.isOffered(
            fake, currentVersion: "1.0.0", osVersion: ProcessInfo.processInfo.operatingSystemVersion, now: start,
            skippedVersion: nil))
    }
}

/// The coordinator with every outside thing injected: the store's answer, the clock, the listening state, the alert and
/// the store link. Nothing here touches the network, `UserDefaults.standard` or an NSAlert.
@Suite("Update check coordinator")
@MainActor
struct UpdateCheckCoordinatorTests {
    @MainActor
    final class Harness {
        var now = start
        var latest: AppStoreRelease? = release()
        var choice: UpdateAlertChoice = .remindLater
        var busy = false
        var fetchCount = 0
        var alerts: [String] = []
        var manualResults: [ManualCheckResult] = []
        var opened: [String] = []
        let preferences: UpdateCheckPreferences
        let suite: String
        let defaults: UserDefaults
        var coordinator: UpdateCheckCoordinator!

        init(isAvailable: Bool = true, retry: Duration = .milliseconds(20)) {
            suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            preferences = UpdateCheckPreferences(defaults: defaults)
            coordinator = UpdateCheckCoordinator(
                isAvailable: isAvailable, preferences: preferences,
                fetchLatest: { [unowned self] in
                    fetchCount += 1
                    return latest
                },
                currentVersion: "1.0.1",
                osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1),
                now: { [unowned self] in now },
                isBusy: { [unowned self] in busy },
                busyRetryDelay: retry,
                presentAlert: { [unowned self] release, _ in
                    alerts.append(release.version)
                    return choice
                },
                presentManualResult: { [unowned self] in manualResults.append($0) },
                openStore: { [unowned self] in opened.append($0.version) })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    @Test("A due release alerts once, and Remind Me Later holds it back for three days")
    func remindLater() async {
        let h = Harness()
        defer { h.cleanUp() }
        await h.coordinator.checkAutomatically()
        #expect(h.alerts == ["1.0.2"])
        #expect(h.coordinator.offeredRelease?.version == "1.0.2")
        #expect(h.preferences.snoozeUntil == start.addingTimeInterval(3 * day))
        #expect(h.preferences.lastCheckDate == start)

        h.now = start.addingTimeInterval(day)
        await h.coordinator.checkAutomatically()
        #expect(h.alerts.count == 1, "still snoozed a day later")
        #expect(h.coordinator.offeredRelease != nil, "the menu row stays through a snooze")

        h.now = start.addingTimeInterval(3 * day)
        await h.coordinator.checkAutomatically()
        #expect(h.alerts.count == 2, "the snooze is over")
    }

    @Test("Skip This Version hides that version, and a newer one comes back")
    func skip() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.choice = .skip
        await h.coordinator.checkAutomatically()
        #expect(h.preferences.skippedVersion == "1.0.2")
        #expect(h.coordinator.offeredRelease == nil)
        await h.coordinator.checkAutomatically()
        #expect(h.alerts.count == 1)

        h.latest = release(version: "1.0.3")
        await h.coordinator.checkAutomatically()
        #expect(h.alerts == ["1.0.2", "1.0.3"])
    }

    @Test("Update opens the store page and nothing else changes")
    func update() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.choice = .update
        await h.coordinator.checkAutomatically()
        #expect(h.opened == ["1.0.2"])
        #expect(h.preferences.snoozeUntil == nil)
        #expect(h.preferences.skippedVersion == nil)
    }

    @Test("A young release, an older one and a too-new one raise no alert and no row")
    func notOffered() async {
        let h = Harness()
        defer { h.cleanUp() }
        for r in [release(age: 3_600), release(version: "1.0.1"), release(minimumOS: "99.0")] {
            h.latest = r
            await h.coordinator.checkAutomatically()
        }
        #expect(h.alerts.isEmpty)
        #expect(h.coordinator.offeredRelease == nil)
    }

    @Test("A lookup with no answer (not on sale yet, offline) is a silent no-op")
    func silentWithoutAnswer() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.latest = nil
        await h.coordinator.checkAutomatically()
        #expect(h.fetchCount == 1)
        #expect(h.alerts.isEmpty && h.manualResults.isEmpty)
        #expect(h.preferences.lastCheckDate == nil, "no answer, no check recorded")
        #expect(h.coordinator.offeredRelease == nil)
    }

    @Test("Turned off or not available: nothing is fetched")
    func offOrUnavailable() async {
        let off = Harness()
        defer { off.cleanUp() }
        off.preferences.isEnabled = false
        await off.coordinator.checkAutomatically()
        #expect(off.fetchCount == 0)

        let unavailable = Harness(isAvailable: false)
        defer { unavailable.cleanUp() }
        await unavailable.coordinator.checkAutomatically()
        await unavailable.coordinator.checkManually()
        unavailable.coordinator.start()
        #expect(unavailable.fetchCount == 0)
        #expect(!unavailable.coordinator.isScheduled)
        #expect(unavailable.manualResults.isEmpty)
    }

    @Test("While listening is busy the alert waits, then shows when it is idle")
    func waitsForIdle() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.busy = true
        await h.coordinator.checkAutomatically()
        #expect(h.alerts.isEmpty)
        #expect(h.coordinator.offeredRelease != nil, "the menu row shows meanwhile")
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.alerts.isEmpty, "still busy")

        h.busy = false
        for _ in 0..<50 where h.alerts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(h.alerts == ["1.0.2"])
    }

    @Test("A waiting alert is decided again: skipping meanwhile cancels it")
    func waitingAlertIsRechecked() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.busy = true
        await h.coordinator.checkAutomatically()
        h.preferences.skippedVersion = "1.0.2"
        h.busy = false
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.alerts.isEmpty)
    }

    @Test("A manual check ignores age, skip, snooze and a busy session, and always answers")
    func manual() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.busy = true
        h.preferences.skippedVersion = "1.0.2"
        h.preferences.snoozeUntil = start.addingTimeInterval(day)
        h.latest = release(age: 60)
        h.choice = .update
        await h.coordinator.checkManually()
        #expect(h.alerts == ["1.0.2"])
        #expect(h.opened == ["1.0.2"])

        h.latest = release(version: "1.0.1")
        await h.coordinator.checkManually()
        h.latest = release(minimumOS: "99.0")
        await h.coordinator.checkManually()
        h.latest = nil
        await h.coordinator.checkManually()
        #expect(h.manualResults == [
            .upToDate(current: "1.0.1"), .needsNewerMacOS(version: "1.0.2", minimum: "99.0"), .failed,
        ])
    }

    @Test("The row's Update Available alert works during a snooze")
    func rowDuringSnooze() async {
        let h = Harness()
        defer { h.cleanUp() }
        await h.coordinator.checkAutomatically()
        #expect(h.preferences.snoozeUntil != nil)
        h.choice = .update
        h.coordinator.presentOfferedUpdate()
        #expect(h.alerts.count == 2)
        #expect(h.opened == ["1.0.2"])
    }

    @Test("The first check is delayed by the configuration, not run at once")
    func startDoesNotCheckAtOnce() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        h.coordinator.start()
        #expect(h.coordinator.isScheduled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.fetchCount == 0, "the first check is 20 seconds after launch")
        h.coordinator.stop()
        #expect(!h.coordinator.isScheduled)
    }
}
