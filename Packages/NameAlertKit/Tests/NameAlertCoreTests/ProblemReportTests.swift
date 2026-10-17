import Foundation
@testable import NameAlertCore
import Testing

@Suite("ProblemReport")
struct ProblemReportTests {
    private func entry(_ n: Int, threads: Int = 0, pad: Int = 0) -> ProblemReport.CrashEntry {
        let json = DiagnosticsFixtures.crashJSON(frames: [("Takeheed", n, 0)], extraThreads: threads, note: String(repeating: "x", count: pad))
        return ProblemReport.CrashEntry(
            signature: "sig\(n)", metricKitJSON: try! JSONDecoder().decode(JSONValue.self, from: json),
            appVersion: "1", build: "1", osVersion: "26", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(n))
        )
    }

    private func report(logs: String? = nil, crashes: [ProblemReport.CrashEntry]? = nil) -> ProblemReport {
        ProblemReport(message: "Something went wrong here", environment: DiagnosticsFixtures.environment, crashes: crashes, logs: logs)
    }

    @Test func limitsAndMessageValidation() {
        #expect(FeedbackLimits.messageMin == 10 && FeedbackLimits.messageMax == 5000)
        #expect(FeedbackLimits.logEntriesMax == 500 && FeedbackLimits.logBytesMax == 204_800)
        #expect(FeedbackLimits.reportBytesMax == 262_144 && FeedbackLimits.crashesMax == 5)
        #expect(!FeedbackLimits.isValidMessage("too short"))
        #expect(FeedbackLimits.isValidMessage(String(repeating: "a", count: 10)))
        #expect(FeedbackLimits.isValidMessage(String(repeating: "a", count: 5000)))
        #expect(!FeedbackLimits.isValidMessage(String(repeating: "a", count: 5001)))
        // 2501 emoji = 5002 UTF-16 units, 2501 characters.
        #expect(!FeedbackLimits.isValidMessage(String(repeating: "😀", count: 2501)))
        #expect(FeedbackLimits.isValidMessage(String(repeating: "😀", count: 2500)))
    }

    @Test func environmentLocaleLosesSuffix() {
        #expect(DiagnosticsFixtures.environment.locale == "en_US")
    }

    @Test func schemaVersionAndSortedCompactEncoding() throws {
        let r = report()
        #expect(r.schemaVersion == 1)
        let text = String(decoding: try r.encoded(), as: UTF8.self)
        #expect(text.hasPrefix(#"{"environment":{"#))
        #expect(!text.contains("\n"))
        #expect(text.contains(#""schemaVersion":1"#))
    }

    @Test func previewBytesEqualEncodedBytes() throws {
        let r = report(logs: "a/b\nc", crashes: [entry(1)])
        #expect(Data(r.previewText().utf8) == (try r.encoded()))
    }

    @Test func fitsUntouchedWhenSmall() {
        let r = report(logs: "line", crashes: [entry(1)])
        let fit = r.fitted(maxBytes: 100_000)
        #expect(fit.report == r && fit.droppedCrashCount == 0)
    }

    @Test func logsShrinkFirstFromTheFront() throws {
        let lines = (0..<400).map { "line-\($0) " + String(repeating: "z", count: 40) }
        let r = report(logs: lines.joined(separator: "\n"), crashes: [entry(1, threads: 3)])
        let limit = try r.encoded().count - 4000
        let fit = r.fitted(maxBytes: limit)
        let logs = try #require(fit.report.logs)
        #expect(logs.hasPrefix(ProblemReport.removedLinesMarker))
        #expect(logs.hasSuffix(lines.last!))
        #expect(!logs.contains("line-0 "))
        #expect(fit.report.crashes == r.crashes)
        #expect(try fit.report.encoded().count <= limit)
        #expect(fit.report.message == r.message && fit.report.environment == r.environment)
    }

    @Test func crashesReduceToCrashedThreadBeforeAnyIsDropped() throws {
        let crashes = [entry(1, threads: 40), entry(2, threads: 40)]
        let r = report(logs: nil, crashes: crashes)
        let full = try r.encoded().count
        let fit = r.fitted(maxBytes: full - 500)
        #expect(fit.droppedCrashCount == 0)
        #expect(fit.report.crashes?.count == 2)
        let reduced = try #require(fit.report.crashes?.first)
        guard case .object(let root) = reduced.metricKitJSON, case .int(let omitted)? = root["omittedThreads"] else {
            Issue.record("no omittedThreads"); return
        }
        #expect(omitted == 40)
    }

    @Test func oldestCrashesDropLastAndNewestSurvives() throws {
        let crashes = (1...4).map { entry($0, pad: 3000) }
        let r = report(crashes: crashes)
        let fit = r.fitted(maxBytes: 7000)
        #expect(fit.droppedCrashCount > 0)
        #expect(fit.report.crashes?.last == crashes.last)
        #expect(fit.report.crashes?.first != crashes.first)
    }

    @Test func logsDropEntirelyWhenNoLineFits() throws {
        let r = report(logs: String(repeating: "q", count: 5000))
        let fit = r.fitted(maxBytes: try r.encoded().count - 4990)
        #expect(fit.report.logs == nil)
    }
}
