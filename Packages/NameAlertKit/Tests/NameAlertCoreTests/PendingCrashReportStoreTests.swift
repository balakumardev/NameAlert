import Foundation
@testable import NameAlertCore
import Testing

@Suite("PendingCrashReportStore")
struct PendingCrashReportStoreTests {
    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let fallback = CrashVersionInfo(appVersion: "9.9", build: "99", osVersion: "macOS X")
    private let own: Set<String> = ["Takeheed"]

    private func crash(_ n: Int, note: String = "") -> Data {
        DiagnosticsFixtures.crashJSON(frames: [("Takeheed", n, 0)], note: note)
    }

    private func store(_ dir: URL, _ clock: Clock) -> PendingCrashReportStore {
        PendingCrashReportStore(directory: dir, now: { clock.date }, ownBinaries: own)
    }

    @Test func redactsAndStores() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            let saved = try #require(s.save(diagnosticJSON: crash(1, note: #"/Users/jane/x"#), crashedAt: clock.date, fallback: fallback))
            #expect(saved.id.count == 16)
            #expect(saved.appVersion == "1.2")
            #expect(saved.build == "99")
            let onDisk = try String(contentsOf: dir.appendingPathComponent("\(saved.id).json"), encoding: .utf8)
            #expect(!onDisk.contains("jane"))
            #expect(onDisk.contains("/Users/<redacted>/x"))
            #expect(s.pending() == [saved])
        }
    }

    @Test func sameCrashStoredOnce() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            let a = s.save(diagnosticJSON: crash(1), crashedAt: clock.date, fallback: fallback)
            let b = s.save(diagnosticJSON: crash(1), crashedAt: clock.date.addingTimeInterval(5), fallback: fallback)
            #expect(a?.id == b?.id)
            #expect(s.pending().count == 1)
        }
    }

    @Test func keepsOnlyFiveNewest() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            for n in 0..<7 {
                s.save(diagnosticJSON: crash(n), crashedAt: clock.date.addingTimeInterval(Double(n)), fallback: fallback)
            }
            let kept = s.pending()
            #expect(kept.count == 5)
            #expect(kept.map(\.crashedAt) == (2..<7).map { clock.date.addingTimeInterval(Double($0)) })
        }
    }

    @Test func purgesAfterThirtyDays() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            s.save(diagnosticJSON: crash(1), crashedAt: clock.date, fallback: fallback)
            clock.date = clock.date.addingTimeInterval(29 * 86_400)
            #expect(s.pending().count == 1)
            clock.date = clock.date.addingTimeInterval(2 * 86_400)
            #expect(s.pending().isEmpty)
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(left.isEmpty)
        }
    }

    @Test func tooOldCrashIsNotKept() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            #expect(s.save(diagnosticJSON: crash(1), crashedAt: clock.date.addingTimeInterval(-40 * 86_400), fallback: fallback) == nil)
        }
    }

    @Test func corruptFileIsSkippedNotFatal() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            let saved = try #require(s.save(diagnosticJSON: crash(1), crashedAt: clock.date, fallback: fallback))
            try Data("{ not json".utf8).write(to: dir.appendingPathComponent("deadbeefdeadbeef.json"))
            #expect(s.pending() == [saved])
        }
    }

    @Test func rejectsNonObjectAndRemoves() throws {
        try DiagnosticsFixtures.withTemporaryDirectory { dir in
            let clock = Clock()
            let s = store(dir, clock)
            #expect(s.save(diagnosticJSON: Data("[1,2]".utf8), crashedAt: clock.date, fallback: fallback) == nil)
            let a = try #require(s.save(diagnosticJSON: crash(1), crashedAt: clock.date, fallback: fallback))
            let b = try #require(s.save(diagnosticJSON: crash(2), crashedAt: clock.date.addingTimeInterval(1), fallback: fallback))
            s.remove(ids: [a.id, "../evil"])
            #expect(s.pending() == [b])
            s.removeAll()
            #expect(s.pending().isEmpty)
        }
    }

    @Test func preferencesDefaultOnAndPersist() throws {
        let suite = "crash-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = CrashReportPreferences(defaults: defaults)
        #expect(CrashReportPreferences.offerToSendKey == "crashReports.offerToSend")
        #expect(prefs.offerToSend)
        prefs.offerToSend = false
        #expect(!CrashReportPreferences(defaults: defaults).offerToSend)
    }

    @Test func appPathsAccessorEndsInPendingCrashReports() {
        #expect(AppPaths.pendingCrashReportsDirectory.lastPathComponent == "PendingCrashReports")
    }
}
