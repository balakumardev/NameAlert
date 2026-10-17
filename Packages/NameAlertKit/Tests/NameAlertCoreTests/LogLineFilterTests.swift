import Foundation
@testable import NameAlertCore
import Testing

@Suite("LogLineFilter")
struct LogLineFilterTests {
    private func line(_ n: Int, _ category: String = "App", _ message: String = "m", _ level: DiagnosticLogLevel = .info) -> DiagnosticLogLine {
        DiagnosticLogLine(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)), category: category, message: message, level: level)
    }

    @Test func dropsDebugButKeepsOthersByDefault() {
        let f = LogLineFilter()
        #expect(!f.includes(line(1, "App", "x", .debug)))
        for level in [DiagnosticLogLevel.info, .notice, .error, .fault] { #expect(f.includes(line(1, "App", "x", level))) }
    }

    @Test func excludesCategoriesAndPrefixes() {
        let f = LogLineFilter(excludedCategories: ["Heard"], excludedMessagePrefixes: ["Sent to "])
        #expect(!f.includes(line(1, "Heard", "x")))
        #expect(!f.includes(line(1, "App", "Sent to https://a.b")))
        #expect(f.includes(line(1, "App", "Not Sent to")))
    }

    @Test func formatsOldestFirstRedactedAndLimited() {
        let out = LogLineFilter().format([line(1, "A", "one"), line(2, "B", "/Users/jane/x"), line(3, "C", "three")], limit: 2, maxBytes: 10_000)
        let rows = out.components(separatedBy: "\n")
        #expect(rows.count == 2)
        #expect(rows[0] == "2023-11-14T22:13:22Z [B] /Users/<redacted>/x")
        #expect(rows[1].hasSuffix("[C] three"))
    }

    @Test func dropsOldestToFitBytes() {
        let lines = (0..<10).map { line($0, "A", "message-\($0)") }
        let out = LogLineFilter().format(lines, limit: 100, maxBytes: 120)
        #expect(out.utf8.count <= 120)
        #expect(out.hasSuffix("message-9"))
        #expect(!out.contains("message-0"))
        #expect(LogLineFilter().format([], limit: 5, maxBytes: 100) == "")
        #expect(LogLineFilter().format(lines, limit: 5, maxBytes: 3) == "")
    }
}
