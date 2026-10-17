import Foundation
import NameAlertCore
import Observation

/// The words of the Report a Problem window.
enum ReportProblemCopy {
    static let windowTitle = "Report a Problem"
    static let messageLabel = "What happened?"
    static let diagnosticsToggle = "Include diagnostics"
    static let diagnosticsDetail =
        "App version, macOS version, Mac model, and the speech engine and audio source in use. Never what was heard, your keywords, rules, addresses or secrets."
    static let logsToggle = "Include this session's log"
    static let logsDetail =
        "Takeheed's own log lines since it opened. They can include the names of apps and audio devices and file names. Your Mac account name is hidden."
    static let previewLabel = "This is exactly what will be copied"
    static let copyAndEmail = "Copy Report & Open Email"
    static let tooShort = "At least 10 characters"
    static let tooLong = "Too long. Please shorten it."
    static let collectingLogs = "Collecting the log…"
    static let noLogs = "No log lines were available, so none are included."
    static let copied = "The report is on your clipboard."
    static let copiedDetail = "Paste it into the email that opened. If no email app opened, write to the support address and paste it there."
    static let close = "Close"
    static let mailSubject = "Takeheed problem report"
    static let handoff = "Nothing is sent from the app. Copying the report and emailing it is up to you."
}

/// The Report a Problem form's state and rules: when Copy is allowed and what exactly is copied. The window
/// (`ReportProblemView`) only draws it. Nothing here sends anything: the report goes to the pasteboard and the person's
/// mail app opens.
@MainActor
@Observable
final class ReportProblemModel {
    enum State: Equatable {
        case editing
        case copied
    }

    var message = ""
    var includeDiagnostics = true
    var includeLogs = false
    private(set) var logs: String?
    private(set) var isLoadingLogs = false
    /// The log was asked for and none came back.
    private(set) var logsUnavailable = false
    private(set) var state: State = .editing

    @ObservationIgnored private let environment: ProblemReportEnvironment
    @ObservationIgnored private let loadLogs: () async -> String?
    @ObservationIgnored private let deliver: @MainActor (_ text: String, _ subject: String) -> Void
    @ObservationIgnored private var logsRequested = false

    init(
        environment: ProblemReportEnvironment,
        loadLogs: @escaping () async -> String? = AppLogCollector.collectText,
        deliver: @escaping @MainActor (_ text: String, _ subject: String) -> Void = { text, subject in
            ReportDelivery.copyAndOpenMail(text: text, subject: subject)
        }
    ) {
        self.environment = environment
        self.loadLogs = loadLogs
        self.deliver = deliver
    }

    // MARK: Rules

    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Counted in UTF-16 code units: an emoji is two.
    var messageIsTooShort: Bool { trimmedMessage.utf16.count < FeedbackLimits.messageMin }
    var messageIsTooLong: Bool { trimmedMessage.utf16.count > FeedbackLimits.messageMax }

    /// Copy is off until the message fits the limits, and while the log is still being read, so the preview is always
    /// what is copied.
    var canCopy: Bool {
        state == .editing && !isLoadingLogs && FeedbackLimits.isValidMessage(message)
    }

    // MARK: What is copied

    /// What the report says about this Mac when "Include diagnostics" is off: the version of the app, which support
    /// needs to read the rest, and nothing else.
    static func minimalEnvironment(of environment: ProblemReportEnvironment) -> ProblemReportEnvironment {
        ProblemReportEnvironment(
            appVersion: environment.appVersion, build: environment.build, macOSVersion: "not included",
            macModel: "not included", architecture: "not included", engine: "not included", locale: "not included",
            listeningSource: "not included")
    }

    /// The report cut to the size limit: the message and the environment are never cut.
    var report: ProblemReport {
        ProblemReport(
            message: trimmedMessage,
            environment: includeDiagnostics ? environment : Self.minimalEnvironment(of: environment),
            logs: includeLogs ? logs : nil
        ).fitted().report
    }

    /// The text of `report`, for the preview and for the pasteboard: the very same bytes.
    var previewText: String { report.previewText() }

    // MARK: Actions

    /// Reads the log the first time "Include this session's log" is turned on (it can take a few seconds), and keeps it.
    func logsToggled() async {
        guard includeLogs, !logsRequested else { return }
        logsRequested = true
        isLoadingLogs = true
        if let loaded = await loadLogs(), !loaded.isEmpty {
            logs = loaded
        } else {
            logsUnavailable = true
        }
        isLoadingLogs = false
    }

    func copyAndOpenEmail() {
        guard canCopy else { return }
        deliver(previewText, ReportProblemCopy.mailSubject)
        state = .copied
    }
}
