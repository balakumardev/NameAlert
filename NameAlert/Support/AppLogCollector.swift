import Foundation
import NameAlertCore
import OSLog

/// Reads this run's own log lines for a report: only the app's subsystem, only this process, info level and above,
/// without the lines that can carry something private, with home-folder names hidden.
///
/// What a line says is whatever the app logged. A value logged with `privacy: .private` still reads in full here:
/// `OSLogStore(scope: .currentProcessIdentifier)` hands a process its own private values back unredacted (measured on
/// this Mac, nothing reads `<private>`). So what must stay out of a report is kept out by rule, in
/// `excludedMessagePrefixes`, and the log calls stay as they are for Console. Debug lines, the only place heard text is
/// logged, are left out wholesale. `testEveryPrivateLogCallIsExcluded` fails when a log call that logs a private value
/// is not covered by a prefix below, or a prefix goes stale.
///
/// What stays in, by audit of every info-and-above log call: operational facts (counts, durations, states, engine and
/// model names, error domains and codes, system error descriptions).
enum AppLogCollector {
    /// The subsystem the app logs under.
    static let subsystem = Diagnostics.subsystem

    /// Lines that start with one of these are left out, each because it quotes a value that is private: a path, an
    /// address, a link, an error text that can name an address, or text from the speech library.
    static let excludedMessagePrefixes: [String] = [
        // The path of another copy of the app (it holds the account name).
        "Other copies macOS may open instead of this one",
        // A `takeheed://` link that was not a command: whatever was in it.
        "Ignored a link that is not a",
        // Why a channel's delivery failed: can name an address or an account.
        "Alert delivery failed (",
        // Why a write failed: the system's text names the file's folder.
        "Could not save config.json (",
        "Could not save history.json (",
        "Could not delete it (",
        // The speech library's own messages.
        "whisper.cpp: ",
        // The system's text for why a capture ended.
        "Stopping system audio capture reported:",
    ]

    /// The rule that chooses the lines: no debug lines, none that start with an excluded prefix.
    static let filter = LogLineFilter(excludedMessagePrefixes: excludedMessagePrefixes)

    /// An OSLog level as the filter's level. A level OSLog adds later counts as debug: left out.
    static func level(of level: OSLogEntryLog.Level) -> DiagnosticLogLevel {
        switch level {
        case .info: .info
        case .notice: .notice
        case .error: .error
        case .fault: .fault
        case .debug, .undefined: .debug
        @unknown default: .debug
        }
    }

    /// The word a level goes by in a report.
    static func tag(of level: DiagnosticLogLevel) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        }
    }

    /// This run's lines that `filter` lets through, oldest first, at most `limit` of them, or why the log store could
    /// not be read.
    static func lines(limit: Int = Diagnostics.logLineLimit) async -> Result<[DiagnosticLogLine], LogReadFailure> {
        // Reading the store takes a moment: not on the main thread.
        await Task.detached(priority: .utility) { read(limit: limit) }.value
    }

    struct LogReadFailure: Error, Equatable {
        var description: String
    }

    private static func read(limit: Int) -> Result<[DiagnosticLogLine], LogReadFailure> {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0), matching: predicate)
            var newest: [DiagnosticLogLine] = []
            for case let entry as OSLogEntryLog in entries {
                let line = DiagnosticLogLine(
                    date: entry.date, category: entry.category, message: entry.composedMessage,
                    level: level(of: entry.level))
                guard filter.includes(line) else { continue }
                newest.append(line)
                // Keep the newest while reading, not the whole run.
                if newest.count >= limit * 2 { newest.removeFirst(newest.count - limit) }
            }
            return .success(Array(newest.suffix(limit)))
        } catch {
            return .failure(LogReadFailure(description: error.localizedDescription))
        }
    }

    /// The lines of the text report: `<time> <level> [<category>] <message>`, one line each, home-folder names hidden.
    static func reportLines(from lines: [DiagnosticLogLine]) -> [String] {
        lines.map { line in
            Diagnostics.logLine(
                date: line.date, tag: tag(of: line.level), category: line.category,
                message: DiagnosticRedaction.redactingUserPaths(line.message))
        }
    }

    /// The log as one text for a problem report (`ProblemReport.logs`), or `nil` when it cannot be read or is empty.
    static func collectText() async -> String? {
        guard case .success(let lines) = await lines(limit: FeedbackLimits.logEntriesMax) else { return nil }
        let text = filter.format(lines, limit: FeedbackLimits.logEntriesMax, maxBytes: FeedbackLimits.logBytesMax)
        return text.isEmpty ? nil : text
    }
}
