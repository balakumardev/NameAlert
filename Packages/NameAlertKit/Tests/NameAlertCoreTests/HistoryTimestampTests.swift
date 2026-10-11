import Foundation
@testable import NameAlertCore
import Testing

@Suite("HistoryTimestamp")
struct HistoryTimestampTests {
    @Test func millisecondTimestampsRoundTripExactly() {
        var generator = SeededGenerator(state: 1_760_175_000)
        let oracle = ISO8601DateFormatter()  // whole seconds only, and exact on every macOS version
        var wrongText: [String] = []
        var wrongDate: [String] = []
        for _ in 0..<20_000 {
            // Any millisecond from 2000-01-01 to 2099-12-31.
            let milliseconds = Int64.random(in: 946_684_800_000...4_102_444_799_999, using: &generator)
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)

            let text = HistoryTimestamp.string(from: date)
            let wholeSecond = oracle.string(from: Date(timeIntervalSince1970: Double(milliseconds / 1000)))
            let expected = String(wholeSecond.dropLast()) + String(format: ".%03d", Int(milliseconds % 1000)) + "Z"
            if text != expected { wrongText.append("\(text) should be \(expected)") }
            if HistoryTimestamp.date(from: text) != date { wrongDate.append(text) }
        }
        #expect(wrongText.isEmpty, "\(wrongText.prefix(3))")
        #expect(wrongDate.isEmpty, "\(wrongDate.prefix(3))")
    }

    @Test func timestampsRoundToTheNearestMillisecond() {
        let cases: [(seconds: Double, text: String)] = [
            (1_760_175_000.1234, "2025-10-11T09:30:00.123Z"),
            (1_760_175_000.1236, "2025-10-11T09:30:00.124Z"),
            (1_760_175_000.9996, "2025-10-11T09:30:01.000Z"),  // rounds up into the next second ...
            (1_760_175_059.9996, "2025-10-11T09:31:00.000Z"),  // ... and the next minute
        ]
        for (seconds, text) in cases {
            #expect(HistoryTimestamp.string(from: Date(timeIntervalSince1970: seconds)) == text, "\(seconds)")
        }
    }

    @Test func timestampsBeforeTheEpochKeepTheirFraction() {
        // The fraction always counts forwards from the whole second, so -0.5 is 23:59:59.500 and not 00.500.
        let cases: [(seconds: Double, text: String)] = [
            (0, "1970-01-01T00:00:00.000Z"),
            (-0.5, "1969-12-31T23:59:59.500Z"),
            (-0.001, "1969-12-31T23:59:59.999Z"),
            (-1.25, "1969-12-31T23:59:58.750Z"),
        ]
        for (seconds, text) in cases {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(HistoryTimestamp.string(from: date) == text, "\(seconds)")
            #expect(HistoryTimestamp.date(from: text) == date, "\(text)")
        }
    }

    @Test func extremeTimestampsDoNotCrash() {
        // None of these can come from a real clock, but writing the file must never trap on one.
        let dates = [
            Date.distantPast, Date.distantFuture,
            Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: 1e300),
        ]
        for date in dates {
            let text = HistoryTimestamp.string(from: date)
            #expect(text.count == 24, "\(text)")  // yyyy-MM-ddTHH:mm:ss.SSSZ
            #expect(HistoryTimestamp.date(from: text) != nil, "\(text)")
        }
    }

    @Test func timestampTextIsReadLeniently() {
        let cases: [(text: String, seconds: Double)] = [
            ("2025-10-11T09:30:00Z", 1_760_175_000),
            ("2025-10-11T09:30:00.5Z", 1_760_175_000.5),
            ("2025-10-11T09:30:00.123Z", 1_760_175_000.123),
            ("2025-10-11T09:30:00.123456Z", 1_760_175_000.123456),
            ("2025-10-11T09:30:00.1234567890Z", 1_760_175_000.123456),  // only the first six digits count
        ]
        for (text, seconds) in cases {
            #expect(HistoryTimestamp.date(from: text) == Date(timeIntervalSince1970: seconds), "\(text)")
        }
    }

    @Test(arguments: [
        "", "yesterday", "2025-10-11", "1760175000",
        "2025-10-11T09:30:00.Z",  // a dot with no digits after it
        "2025-10-11T09:30:00.12.3Z",  // a second dot
    ])
    func unreadableTimestampTextIsRejected(text: String) {
        #expect(HistoryTimestamp.date(from: text) == nil)
    }
}
