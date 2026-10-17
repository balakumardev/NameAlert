import Foundation
import NameAlertCore
import Observation

/// The crash report window's state and rules: what the report holds, and what happens to the crash files after each
/// choice. The window (`CrashReportView`) only draws it.
///
/// The model keeps the crashes that were pending when it was made, and removes only those: a crash that arrives while
/// the window is open waits for the next time. What the report holds is worked out once, then: the crashes are shrunk
/// to the thread that crashed where the report would be too big, and if that is not enough the oldest are left out.
/// "Copy Report & Open Email" removes only the crashes that are in the report (`includedReports`); the ones left out
/// stay for the next launch. The note changes with every keystroke, so it is the only part put together again.
///
/// Nothing here sends anything. The report goes to the pasteboard and the person's mail app opens; the person sends it.
@MainActor
@Observable
final class CrashReportModel {
    enum State: Equatable {
        case ready
        case copied
    }

    var note = ""
    var dontAskAgain = false
    private(set) var state: State = .ready

    /// The crashes this window is about, oldest first.
    let reports: [PendingCrashReport]

    /// The reports whose crashes are in `report`: all of `reports`, less the oldest few when they did not fit even after
    /// shrinking.
    let includedReports: [PendingCrashReport]

    /// A note of the longest length can be made of characters JSON writes as six bytes (`\u0001`), so that much room is
    /// kept for it.
    static let messageReserve = FeedbackLimits.messageMax * 6

    @ObservationIgnored private let store: PendingCrashReportStore
    @ObservationIgnored private let preferences: CrashReportPreferences
    @ObservationIgnored private let environment: ProblemReportEnvironment
    @ObservationIgnored private let includedCrashes: [ProblemReport.CrashEntry]
    @ObservationIgnored private let deliver: @MainActor (_ text: String, _ subject: String) -> Void
    @ObservationIgnored private var previewCache: (note: String, text: String)?

    init(
        store: PendingCrashReportStore,
        preferences: CrashReportPreferences,
        environment: ProblemReportEnvironment,
        deliver: @escaping @MainActor (_ text: String, _ subject: String) -> Void = { text, subject in
            ReportDelivery.copyAndOpenMail(text: text, subject: subject)
        }
    ) {
        self.store = store
        self.preferences = preferences
        self.environment = environment
        self.deliver = deliver

        let pending = store.pending()
        let fitted = ProblemReport(
            message: "", environment: environment, crashes: pending.map(\.crashEntry)
        ).fitted(maxBytes: FeedbackLimits.reportBytesMax - Self.messageReserve)
        reports = pending
        includedReports = Array(pending.dropFirst(fitted.droppedCrashCount))
        includedCrashes = fitted.report.crashes ?? []
    }

    // MARK: Rules

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Counted in UTF-16 code units, like the limit itself: an emoji is two.
    var noteIsTooLong: Bool { trimmedNote.utf16.count > FeedbackLimits.messageMax }

    var canCopy: Bool { state == .ready && !noteIsTooLong }

    // MARK: What is copied

    /// Exactly what "Copy Report & Open Email" puts on the pasteboard: the crashes, oldest first, the note as the
    /// message, and the environment. It fits `FeedbackLimits.reportBytesMax` for any note the window lets through.
    var report: ProblemReport {
        ProblemReport(message: trimmedNote, environment: environment, crashes: includedCrashes)
    }

    /// `report` as the text shown under "Show the report" and copied: the very same bytes. Put together again only when
    /// the note changed.
    var previewText: String {
        let note = trimmedNote
        if let cached = previewCache, cached.note == note { return cached.text }
        let text = report.previewText()
        previewCache = (note, text)
        return text
    }

    // MARK: Actions

    /// Copies the report, opens a message to the support address, removes the crashes that were in the report, and
    /// applies "Don't ask again".
    func copyAndOpenEmail() {
        guard canCopy else { return }
        deliver(previewText, CrashReportCopy.mailSubject)
        finish(removing: includedReports)
        state = .copied
    }

    /// "Don't Send": every crash the window listed is deleted, the ones that would not have fit too, and "Don't ask
    /// again" applies.
    func dontSend() {
        finish(removing: reports)
    }

    private func finish(removing removed: [PendingCrashReport]) {
        store.remove(ids: removed.map(\.id))
        if dontAskAgain {
            preferences.offerToSend = false
        }
    }
}
