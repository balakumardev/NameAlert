import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import Observation

/// The App Store update check: looks up the newest Takeheed now and then, offers a newer one in the menu bar window and
/// shows an alert, never while listening is starting or going on. It only links to the Mac App Store page; it never
/// downloads or installs anything.
///
/// A check can fail in any number of ways (no network, Apple rate limiting, an app that is not on sale yet) and every
/// one of them is silent. A manual check says so.
@MainActor
@Observable
final class UpdateCheckCoordinator {

    /// A newer release shown in the menu bar window: it runs on this Mac, has been on sale a day and is not the skipped
    /// version. Stays set through a snooze.
    private(set) var offeredRelease: AppStoreRelease?

    /// When the App Store last answered.
    private(set) var lastCheckDate: Date?

    /// False in a build that does not check for updates (the disk image, a build from source). Nothing below runs then.
    @ObservationIgnored let isAvailable: Bool

    @ObservationIgnored private let preferences: UpdateCheckPreferences
    @ObservationIgnored private let fetchLatest: () async -> AppStoreRelease?
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let osVersion: OperatingSystemVersion
    @ObservationIgnored private let configuration: UpdateCheckConfiguration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let busyRetryDelay: Duration
    @ObservationIgnored private let presentAlert: @MainActor (AppStoreRelease, String) -> UpdateAlertChoice
    @ObservationIgnored private let presentManualResult: @MainActor (ManualCheckResult) -> Void
    @ObservationIgnored private let openStore: @MainActor (AppStoreRelease) -> Void
    @ObservationIgnored private let schedulePresentation: (@escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private let logger = Log.logger("updates")

    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var waitingTask: Task<Void, Never>?
    @ObservationIgnored private var isAlerting = false
    @ObservationIgnored private var isCheckingManually = false

    /// `schedulePresentation` runs an alert. The app hands it the main run loop, so a modal alert does not hold up the
    /// main queue; tests run it at once.
    init(
        isAvailable: Bool,
        preferences: UpdateCheckPreferences,
        fetchLatest: @escaping () async -> AppStoreRelease?,
        currentVersion: String,
        osVersion: OperatingSystemVersion,
        configuration: UpdateCheckConfiguration = .standard,
        now: @escaping () -> Date = { Date() },
        isBusy: @escaping @MainActor () -> Bool = { false },
        busyRetryDelay: Duration = .seconds(60),
        presentAlert: @escaping @MainActor (AppStoreRelease, String) -> UpdateAlertChoice,
        presentManualResult: @escaping @MainActor (ManualCheckResult) -> Void,
        openStore: @escaping @MainActor (AppStoreRelease) -> Void,
        schedulePresentation: @escaping (@escaping @MainActor () -> Void) -> Void = { work in work() }
    ) {
        self.isAvailable = isAvailable
        self.preferences = preferences
        self.fetchLatest = fetchLatest
        self.currentVersion = currentVersion
        self.osVersion = osVersion
        self.configuration = configuration
        self.now = now
        self.isBusy = isBusy
        self.busyRetryDelay = busyRetryDelay
        self.presentAlert = presentAlert
        self.presentManualResult = presentManualResult
        self.openStore = openStore
        self.schedulePresentation = schedulePresentation
        self.lastCheckDate = preferences.lastCheckDate
    }

    /// A coordinator for a build that never checks: what tests and renders get unless they bring their own.
    static func unavailable() -> UpdateCheckCoordinator {
        UpdateCheckCoordinator(
            isAvailable: false,
            preferences: UpdateCheckPreferences(defaults: UserDefaults(suiteName: "dev.balakumar.namealert.updates.\(UUID().uuidString)") ?? .standard),
            fetchLatest: { nil }, currentVersion: "0", osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            presentAlert: { _, _ in .remindLater }, presentManualResult: { _ in }, openStore: { _ in })
    }

    // MARK: Whether an alert may interrupt

    /// An automatic alert waits while listening is starting or going on: those are the moments a modal alert would take
    /// the person away from what Takeheed is for. Off, snoozed, waiting for a call and an error are idle.
    static func isBusy(_ state: ListeningState) -> Bool {
        switch state {
        case .preparing, .listening: true
        case .off, .waitingForCall, .snoozed, .error: false
        }
    }

    // MARK: Schedule

    /// Starts the daily check: the first one `firstCheckDelay` after this call, then every day plus a random hour. Does
    /// nothing in a build without the update check, or when already started. The setting is read at each check, so
    /// turning it off takes effect without a restart.
    func start() {
        guard isAvailable, schedulerTask == nil else { return }
        let configuration = self.configuration
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(configuration.firstCheckDelay))
            while !Task.isCancelled {
                guard let self else { return }
                if self.preferences.isEnabled { await self.checkAutomatically() }
                let delay = UpdateCheckSchedule.nextDelay(configuration, random: Double.random(in: 0...1))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        waitingTask?.cancel()
        waitingTask = nil
    }

    var isScheduled: Bool { schedulerTask != nil }

    // MARK: Checks

    /// One scheduled check. Records the date, updates the menu offer and, when an alert is due, shows it once listening
    /// is idle. Silent on any failure, and when the app is not on sale yet.
    func checkAutomatically() async {
        guard isAvailable, preferences.isEnabled else { return }
        guard let release = await fetchLatest() else {
            logger.info("Automatic update check: no answer")
            return
        }
        recordCheck()
        updateOffer(for: release)
        guard isDue(release) else { return }
        presentWhenIdle(release)
    }

    /// "Check for Updates…": ignores the snooze, the skipped version, the release's age and whether listening is busy,
    /// and always answers: an alert for a newer version, "You're up to date", "needs a newer macOS", or "couldn't
    /// check" (which is also what an app that is not on sale yet gets).
    func checkManually() async {
        guard isAvailable, !isCheckingManually else { return }
        isCheckingManually = true
        defer { isCheckingManually = false }

        let release = await fetchLatest()
        if let release {
            recordCheck()
            updateOffer(for: release)
        }
        let result = UpdateEligibility.manualResult(release, currentVersion: currentVersion, osVersion: osVersion)
        schedulePresentation { [weak self] in self?.show(result) }
    }

    /// The menu row: the alert for the release on offer, even during a snooze.
    func presentOfferedUpdate() {
        guard let release = offeredRelease else { return }
        schedulePresentation { [weak self] in self?.runAlert(for: release) }
    }

    // MARK: Alert

    private func isDue(_ release: AppStoreRelease) -> Bool {
        UpdateEligibility.shouldAlert(
            release, currentVersion: currentVersion, osVersion: osVersion, now: now(),
            skippedVersion: preferences.skippedVersion, snoozeUntil: preferences.snoozeUntil,
            configuration: configuration)
    }

    /// Shows the alert now, or looks again every `busyRetryDelay` until listening is idle. It is decided again at the
    /// moment of showing: the person may have snoozed, skipped or turned checking off in the meantime.
    private func presentWhenIdle(_ release: AppStoreRelease) {
        waitingTask?.cancel()
        waitingTask = nil
        guard isBusy() else {
            schedulePresentation { [weak self] in self?.presentIfStillDue(release) }
            return
        }
        let delay = busyRetryDelay
        waitingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if !self.isBusy() {
                    self.waitingTask = nil
                    self.schedulePresentation { [weak self] in self?.presentIfStillDue(release) }
                    return
                }
            }
        }
    }

    private func presentIfStillDue(_ release: AppStoreRelease) {
        guard preferences.isEnabled, isDue(release) else { return }
        if isBusy() {
            presentWhenIdle(release)  // listening started while the alert was waiting for its turn
        } else {
            runAlert(for: release)
        }
    }

    private func show(_ result: ManualCheckResult) {
        if case .available(let release) = result {
            runAlert(for: release)
        } else {
            presentManualResult(result)
        }
    }

    /// At most one alert at a time: a second request while one is up is dropped.
    private func runAlert(for release: AppStoreRelease) {
        guard !isAlerting else { return }
        isAlerting = true
        defer { isAlerting = false }
        apply(presentAlert(release, currentVersion), to: release)
    }

    private func apply(_ choice: UpdateAlertChoice, to release: AppStoreRelease) {
        switch choice {
        case .update:
            openStore(release)
        case .remindLater:
            preferences.snoozeUntil = now().addingTimeInterval(configuration.snoozeDuration)
        case .skip:
            preferences.skippedVersion = release.version
            if offeredRelease?.version == release.version { offeredRelease = nil }
        }
    }

    // MARK: State

    private func recordCheck() {
        let date = now()
        preferences.lastCheckDate = date
        lastCheckDate = date
    }

    private func updateOffer(for release: AppStoreRelease) {
        let offered = UpdateEligibility.isOffered(
            release, currentVersion: currentVersion, osVersion: osVersion, now: now(),
            skippedVersion: preferences.skippedVersion, configuration: configuration)
        offeredRelease = offered ? release : nil
    }

    // MARK: The app's coordinator

    /// Runs `work` from the main run loop on a later turn. `runModal` spins a nested run loop, but the main queue is
    /// not drained again while it is already being drained, and main-actor code runs as part of that drain: an alert
    /// shown from it would hold up every other main-actor job until someone answers it.
    nonisolated static func onMainRunLoop(_ work: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { work() } }
    }

    /// The coordinator of the running app. `isBusy` says whether listening is starting or going on.
    static func live(isBusy: @escaping @MainActor () -> Bool) -> UpdateCheckCoordinator {
        let client = AppStoreLookupClient()
        return UpdateCheckCoordinator(
            isAvailable: UpdateDebugHooks.isAvailable,
            preferences: UpdateCheckPreferences(defaults: .standard),
            fetchLatest: {
                if let fake = UpdateDebugHooks.fakeRelease() { return fake }
                return await client.latestRelease()
            },
            currentVersion: AppInfo.version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            isBusy: isBusy,
            presentAlert: { release, current in UpdateAlert.present(release, currentVersion: current) },
            presentManualResult: { UpdateAlert.presentManualResult($0) },
            openStore: { release in
                let url = UpdateStoreLink.pageURL(for: release)
                if !NSWorkspace.shared.open(url) { Log.logger("updates").error("The App Store page did not open") }
            },
            schedulePresentation: onMainRunLoop)
    }
}
