import Foundation

/// The limits a report keeps to.
public enum FeedbackLimits {
    /// Message length bounds, counted in UTF-16 code units.
    public static let messageMin = 10
    public static let messageMax = 5000
    public static let logEntriesMax = 500
    public static let logBytesMax = 204_800
    public static let reportBytesMax = 262_144
    public static let crashesMax = 5

    /// Whether `message` is within the length bounds (UTF-16 units, after trimming whitespace).
    public static func isValidMessage(_ message: String) -> Bool {
        let count = message.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return count >= messageMin && message.utf16.count <= messageMax
    }
}

/// What the report says about this Mac and this install. Never heard words, rule names, addresses or tokens.
public struct ProblemReportEnvironment: Codable, Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var macOSVersion: String
    /// `hw.model`, for example "Mac15,3".
    public var macModel: String
    public var architecture: String
    public var engine: String
    public var locale: String
    /// Which audio source was being listened to ("system", "microphone", "mixed"), not what was heard.
    public var listeningSource: String

    public init(
        appVersion: String, build: String, macOSVersion: String, macModel: String, architecture: String,
        engine: String, locale: String, listeningSource: String
    ) {
        self.appVersion = appVersion
        self.build = build
        self.macOSVersion = macOSVersion
        self.macModel = macModel
        self.architecture = architecture
        self.engine = engine
        self.locale = Self.localeWithoutSuffix(locale)
        self.listeningSource = listeningSource
    }

    /// `en_US@rg=gbzzzz` becomes `en_US`.
    public static func localeWithoutSuffix(_ identifier: String) -> String {
        identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? identifier
    }
}

/// A problem report the person can preview and save or share themselves. Nothing sends it.
public struct ProblemReport: Codable, Equatable, Sendable {
    /// One crash: a redacted MetricKit diagnostic and where it happened.
    public struct CrashEntry: Codable, Equatable, Sendable {
        public var signature: String
        public var metricKitJSON: JSONValue
        public var appVersion: String
        public var build: String
        public var osVersion: String
        public var timestamp: Date

        public init(
            signature: String, metricKitJSON: JSONValue, appVersion: String, build: String, osVersion: String,
            timestamp: Date
        ) {
            self.signature = signature
            self.metricKitJSON = metricKitJSON
            self.appVersion = appVersion
            self.build = build
            self.osVersion = osVersion
            self.timestamp = timestamp
        }
    }

    public var schemaVersion = 1
    public var message: String
    public var environment: ProblemReportEnvironment
    public var crashes: [CrashEntry]?
    public var logs: String?

    public init(
        message: String, environment: ProblemReportEnvironment, crashes: [CrashEntry]? = nil, logs: String? = nil
    ) {
        self.message = message
        self.environment = environment
        self.crashes = crashes
        self.logs = logs
    }

    /// Compact JSON with sorted keys: the bytes of the report.
    public func encoded() throws -> Data {
        try Self.encoder(prettyPrinted: false).encode(self)
    }

    /// The report as text for the preview. It comes from the same encoder as `encoded()`, so its bytes are
    /// exactly `encoded()`'s bytes: what is previewed is what is saved.
    public func previewText() -> String {
        String(decoding: (try? encoded()) ?? Data(), as: UTF8.self)
    }

    private static func encoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Fitting

    public static let removedLinesMarker = "… earlier lines removed\n"

    /// This report cut down to `maxBytes` of JSON, in this order, stopping as soon as it fits:
    /// 1. logs shrink from the front (whole lines, with a marker line), and go entirely if no line fits;
    /// 2. crashes shrink to the crashed thread only, biggest first;
    /// 3. the oldest crashes go, down to the newest one.
    /// The message and environment are never touched. `droppedCrashCount` counts step 3.
    public func fitted(maxBytes: Int = FeedbackLimits.reportBytesMax) -> (report: ProblemReport, droppedCrashCount: Int) {
        var report = self
        guard var size = report.encodedSize, size > maxBytes else { return (report, 0) }

        if let original = report.logs {
            var drop = size - maxBytes + Self.removedLinesMarker.utf8.count
            while true {
                report.logs = Self.logs(original, droppingFirst: drop)
                size = report.encodedSize ?? 0
                if size <= maxBytes || report.logs == nil { break }
                drop += size - maxBytes
            }
        }

        if size > maxBytes, var crashes = report.crashes {
            let byWeight = crashes.indices
                .map { (index: $0, weight: crashes[$0].encodedSize) }
                .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.index < $1.index }
            for (index, _) in byWeight {
                guard let reduced = crashes[index].reducedToCrashedThread() else { continue }
                crashes[index] = reduced
                report.crashes = crashes
                size = report.encodedSize ?? 0
                if size <= maxBytes { break }
            }
        }

        var dropped = 0
        while size > maxBytes, let crashes = report.crashes, crashes.count > 1 {
            report.crashes = Array(crashes.dropFirst())
            dropped += 1
            size = report.encodedSize ?? 0
        }
        return (report, dropped)
    }

    private var encodedSize: Int? {
        try? encoded().count
    }

    private static func logs(_ logs: String, droppingFirst bytes: Int) -> String? {
        var dropped = 0
        var lines = logs.components(separatedBy: "\n")[...]
        while dropped < bytes, let line = lines.first {
            dropped += line.utf8.count + 1
            lines = lines.dropFirst()
        }
        guard !lines.isEmpty else { return nil }
        return removedLinesMarker + lines.joined(separator: "\n")
    }
}

extension ProblemReport.CrashEntry {
    var encodedSize: Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self).count) ?? 0
    }

    /// This crash with only the thread that crashed (`threadAttributed`, else the first), or nil when there is
    /// nothing to leave out. `omittedThreads` says how many stacks went.
    public func reducedToCrashedThread() -> ProblemReport.CrashEntry? {
        guard case .object(let root) = metricKitJSON,
              case .object(let tree)? = root["callStackTree"],
              case .array(let stacks)? = tree["callStacks"],
              stacks.count > 1
        else { return nil }

        let crashed = stacks.first { stack in
            if case .object(let fields) = stack, case .bool(true)? = fields["threadAttributed"] { return true }
            return false
        } ?? stacks[0]

        var reducedTree: [String: JSONValue] = ["callStacks": .array([crashed])]
        if let perThread = tree["callStackPerThread"] { reducedTree["callStackPerThread"] = perThread }

        var reduced: [String: JSONValue] = [
            "callStackTree": .object(reducedTree),
            "omittedThreads": .int(Int64(stacks.count - 1))
        ]
        if let metadata = root["diagnosticMetaData"] { reduced["diagnosticMetaData"] = metadata }

        var entry = self
        entry.metricKitJSON = .object(reduced)
        return entry
    }
}
