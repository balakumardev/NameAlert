import Foundation
import MetricKit
import NameAlertCore

/// Catches the crash reports macOS hands the app after a crash and keeps them, redacted, on this Mac for the crash
/// report window (`CrashReportPromptCoordinator`). Crashes only: no hang, CPU or disk-write diagnostics. It never sends
/// anything and never touches the network.
///
/// MetricKit delivers a crash through `didReceive` a fraction of a second after the app starts again, on a background
/// queue, and only to a build signed with a real team identity: an ad-hoc signed build (the Release builds of the
/// scripts and CI) gets nothing. So `start()` runs first thing at launch. Logs say how many diagnostics came and how
/// many were kept, and nothing else.
final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticsCollector(
        store: .standard, preferences: .standard, fallback: { .current })

    /// Runs on the main actor when a delivery kept at least one new crash report.
    var onNewReports: (@MainActor () -> Void)?

    private let store: PendingCrashReportStore
    private let preferences: CrashReportPreferences
    private let fallback: @Sendable () -> CrashVersionInfo
    private let subscribe: @Sendable (MXMetricManagerSubscriber) -> Void
    private let lock = NSLock()
    private var started = false
    private let logger = Log.logger("crashes")

    init(
        store: PendingCrashReportStore, preferences: CrashReportPreferences,
        fallback: @escaping @Sendable () -> CrashVersionInfo,
        subscribe: @escaping @Sendable (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.add($0) }
    ) {
        self.store = store
        self.preferences = preferences
        self.fallback = fallback
        self.subscribe = subscribe
        super.init()
    }

    /// Subscribes to MetricKit. With the offer off, the crash reports kept from before are deleted: nobody is going to
    /// be asked about them. Safe to call twice.
    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        if !preferences.offerToSend {
            store.removeAll()
        }
        subscribe(self)
    }

    // MARK: MXMetricManagerSubscriber

    /// The crash diagnostics of each payload, each stamped with when the payload ended.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var crashes: [(json: Data, crashedAt: Date)] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                crashes.append((json: crash.jsonRepresentation(), crashedAt: payload.timeStampEnd))
            }
        }
        handle(crashes)
    }

    /// Keeps each diagnostic and tells `onNewReports` (on the main actor) if any was kept. Keeps nothing while the offer
    /// is off.
    func handle(_ diagnostics: [(json: Data, crashedAt: Date)]) {
        guard !diagnostics.isEmpty else { return }
        guard preferences.offerToSend else {
            logger.info("Crash diagnostics received: \(diagnostics.count, privacy: .public); not kept, the offer is off")
            return
        }
        let fallback = fallback()
        var kept = 0
        for diagnostic in diagnostics
        where store.save(diagnosticJSON: diagnostic.json, crashedAt: diagnostic.crashedAt, fallback: fallback) != nil {
            kept += 1
        }
        logger.info("Crash diagnostics received: \(diagnostics.count, privacy: .public), kept: \(kept, privacy: .public)")
        guard kept > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onNewReports?() }
        }
    }
}
