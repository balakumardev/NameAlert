import Foundation

/// How serious a log line is. Mirrors the OSLog levels without importing OSLog, so the filter stays testable.
public enum DiagnosticLogLevel: Int, Sendable, Comparable {
    case debug, info, notice, error, fault

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One line of the app's own log.
public struct DiagnosticLogLine: Equatable, Sendable {
    public var date: Date
    public var category: String
    public var message: String
    public var level: DiagnosticLogLevel

    public init(date: Date, category: String, message: String, level: DiagnosticLogLevel = .info) {
        self.date = date
        self.category = category
        self.message = message
        self.level = level
    }
}

/// Chooses and lays out the log lines that go into a problem report. The app supplies the categories and message
/// prefixes whose lines could carry heard text, addresses or tokens; both lists are empty by default.
public struct LogLineFilter: Sendable, Equatable {
    public var excludedCategories: Set<String>
    public var excludedMessagePrefixes: [String]

    public init(excludedCategories: Set<String> = [], excludedMessagePrefixes: [String] = []) {
        self.excludedCategories = excludedCategories
        self.excludedMessagePrefixes = excludedMessagePrefixes
    }

    /// Not a debug line, not in an excluded category, not starting with an excluded prefix.
    public func includes(_ line: DiagnosticLogLine) -> Bool {
        line.level != .debug
            && !excludedCategories.contains(line.category)
            && !excludedMessagePrefixes.contains { line.message.hasPrefix($0) }
    }

    /// The included lines, newest `limit` of them, oldest first, one per row as
    /// `<ISO 8601 time> [<category>] <message>` with home-folder names redacted. The oldest rows go until the
    /// text is at most `maxBytes` of UTF-8. Empty when nothing is left.
    public func format(_ lines: [DiagnosticLogLine], limit: Int, maxBytes: Int) -> String {
        let formatter = ISO8601DateFormatter()
        var rows = lines.filter(includes).suffix(max(0, limit)).map { line in
            let message = DiagnosticRedaction.redactingUserPaths(line.message)
            return "\(formatter.string(from: line.date)) [\(line.category)] \(message)"
        }[...]
        var bytes = rows.reduce(0) { $0 + $1.utf8.count } + max(0, rows.count - 1)
        while bytes > maxBytes, let oldest = rows.first {
            bytes -= oldest.utf8.count + (rows.count > 1 ? 1 : 0)
            rows = rows.dropFirst()
        }
        return rows.joined(separator: "\n")
    }
}
