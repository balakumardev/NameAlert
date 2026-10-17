import Foundation
import NameAlertCore

/// Decides when the crash report window opens: when a crash report waits and the offer is on, a moment after launch,
/// and not while listening is still starting up (it waits and looks again). Closing the window without a choice keeps
/// the crash files, so the offer comes back at the next launch.
@MainActor
final class CrashReportPromptCoordinator {
    static let shared = CrashReportPromptCoordinator(
        store: .standard, preferences: .standard,
        isBusy: {
            if case .preparing = AppEnvironment.shared.controller.state { return true }
            return false
        },
        openWindow: { AppEnvironment.shared.router.open(.crashReport) })

    private let store: PendingCrashReportStore
    private let preferences: CrashReportPreferences
    private let isBusy: @MainActor () -> Bool
    private let openWindow: @MainActor () -> Void
    private let launchDelay: Duration
    private let retryDelay: Duration
    private let maxRetries: Int

    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isInLaunchDelay = false
    private var retries = 0
    private(set) var hasOpened = false

    init(
        store: PendingCrashReportStore, preferences: CrashReportPreferences,
        isBusy: @escaping @MainActor () -> Bool, openWindow: @escaping @MainActor () -> Void,
        launchDelay: Duration = .seconds(2), retryDelay: Duration = .seconds(5), maxRetries: Int = 12
    ) {
        self.store = store
        self.preferences = preferences
        self.isBusy = isBusy
        self.openWindow = openWindow
        self.launchDelay = launchDelay
        self.retryDelay = retryDelay
        self.maxRetries = maxRetries
    }

    /// Looks at the pending reports once `launchDelay` has passed, so the window does not open while the app is still
    /// starting. Safe to call twice.
    func start() {
        guard startTask == nil else { return }
        isInLaunchDelay = true
        let delay = launchDelay
        startTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.isInLaunchDelay = false
            self.evaluate()
        }
    }

    /// MetricKit delivered a crash. It does that a fraction of a second after launch, so during the launch delay this
    /// does nothing: the look at the end of the delay finds it.
    func reportsArrived() {
        guard !isInLaunchDelay else { return }
        evaluate()
    }

    /// Opens the window when the offer is on and a report is pending, unless listening is starting up: then it looks
    /// again a little later (a few times). Both are checked at the moment of opening.
    func evaluate() {
        guard !hasOpened, preferences.offerToSend, !store.pending().isEmpty else { return }
        if isBusy() {
            scheduleRetry()
            return
        }
        hasOpened = true
        openWindow()
    }

    private func scheduleRetry() {
        guard retryTask == nil, retries < maxRetries else { return }
        retries += 1
        let delay = retryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.evaluate()
        }
    }
}
