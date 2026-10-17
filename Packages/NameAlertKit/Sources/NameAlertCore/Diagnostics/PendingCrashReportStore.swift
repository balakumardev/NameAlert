import CryptoKit
import Foundation

/// The app and system versions a crash report names, for a crash whose own metadata doesn't say.
public struct CrashVersionInfo: Equatable, Sendable {
    public var appVersion: String
    public var build: String
    public var osVersion: String

    public init(appVersion: String, build: String, osVersion: String) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
    }
}

/// One crash kept on this Mac. The MetricKit JSON is already redacted.
public struct PendingCrashReport: Codable, Equatable, Identifiable, Sendable {
    /// First 16 hex characters of a SHA-256 of the redacted JSON, and the file's name.
    public let id: String
    public let signature: String
    public let metricKit: JSONValue
    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let crashedAt: Date

    public var crashEntry: ProblemReport.CrashEntry {
        ProblemReport.CrashEntry(
            signature: signature, metricKitJSON: metricKit, appVersion: appVersion, build: build,
            osVersion: osVersion, timestamp: crashedAt
        )
    }
}

/// Whether the app offers to include a crash in a report. On until turned off.
public struct CrashReportPreferences {
    public static let offerToSendKey = "crashReports.offerToSend"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// True when unset.
    public var offerToSend: Bool {
        get { defaults.object(forKey: Self.offerToSendKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.offerToSendKey) }
    }
}

/// Crash reports kept in a folder the caller names, one JSON file each. At most `maxReports` newest are kept, none
/// for longer than `maxAge`. MetricKit delivers on a background queue, so file operations run under a lock.
public final class PendingCrashReportStore: @unchecked Sendable {
    public static let maxReports = FeedbackLimits.crashesMax
    /// 30 days.
    public static let maxAge: TimeInterval = 2_592_000

    private static let versionFieldLimit = 64

    private let directory: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let ownBinaries: Set<String>
    private let lock = NSLock()

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        ownBinaries: Set<String> = CrashSignature.defaultOwnBinaries
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        self.ownBinaries = ownBinaries
    }

    // MARK: - Save

    /// Keeps a MetricKit crash diagnostic: redacts it (after decoding), names it, writes it atomically and trims the
    /// folder. Nil when `diagnosticJSON` isn't a JSON object, or the crash is too old or too far down to be kept.
    /// The same diagnostic twice is kept once.
    @discardableResult
    public func save(diagnosticJSON: Data, crashedAt: Date, fallback: CrashVersionInfo) -> PendingCrashReport? {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: diagnosticJSON),
              case .object = decoded else { return nil }
        let redacted = DiagnosticRedaction.redact(decoded)
        guard case .object(let redactedObject) = redacted,
              let canonical = try? Self.fileEncoder.encode(redacted),
              let signature = CrashSignature.compute(diagnosticJSON: canonical, ownBinaries: ownBinaries)
        else { return nil }

        let metadata: [String: JSONValue]
        if case .object(let found)? = redactedObject["diagnosticMetaData"] { metadata = found } else { metadata = [:] }

        let report = PendingCrashReport(
            id: Self.shortHash(of: canonical),
            signature: signature,
            metricKit: redacted,
            appVersion: Self.versionField(metadata["appVersion"], fallback: fallback.appVersion),
            build: Self.versionField(metadata["appBuildVersion"], fallback: fallback.build),
            osVersion: Self.versionField(metadata["osVersion"], fallback: fallback.osVersion),
            crashedAt: Date(timeIntervalSince1970: crashedAt.timeIntervalSince1970.rounded(.down))
        )

        lock.lock()
        defer { lock.unlock() }

        let file = fileURL(forID: report.id)
        var kept = report
        if let existing = readReport(at: file), existing.id == report.id {
            kept = existing
        } else {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.fileEncoder.encode(report).write(to: file, options: .atomic)
            } catch {
                return nil
            }
        }

        let remaining = loadLocked()
        return remaining.contains(where: { $0.id == kept.id }) ? kept : nil
    }

    // MARK: - Read and remove

    /// The reports kept, oldest first. Drops what is older than `maxAge`, and files that aren't a report, as it
    /// reads; a corrupt file never hides the others.
    public func pending() -> [PendingCrashReport] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func remove(ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in ids where Self.isValidID(id) {
            try? fileManager.removeItem(at: fileURL(forID: id))
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for file in reportFiles() {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Folder (lock held)

    private func loadLocked() -> [PendingCrashReport] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var reports: [PendingCrashReport] = []
        for file in reportFiles() {
            let name = file.deletingPathExtension().lastPathComponent
            guard let report = readReport(at: file), report.id == name else {
                try? fileManager.removeItem(at: file)
                continue
            }
            if report.crashedAt < cutoff {
                try? fileManager.removeItem(at: file)
                continue
            }
            reports.append(report)
        }
        reports.sort { ($0.crashedAt, $0.id) < ($1.crashedAt, $1.id) }

        if reports.count > Self.maxReports {
            for dropped in reports.prefix(reports.count - Self.maxReports) {
                try? fileManager.removeItem(at: fileURL(forID: dropped.id))
            }
            reports = Array(reports.suffix(Self.maxReports))
        }
        return reports
    }

    private func reportFiles() -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    private func readReport(at file: URL) -> PendingCrashReport? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.makeDecoder().decode(PendingCrashReport.self, from: data)
    }

    private func fileURL(forID id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: - Helpers

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
        }
    }

    private static var fileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func shortHash(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func versionField(_ value: JSONValue?, fallback: String) -> String {
        let text: String
        switch value {
        case .string(let string)?: text = string
        case .int(let number)?: text = String(number)
        default: text = ""
        }
        return clamped(text.isEmpty ? fallback : text, toUTF16Units: versionFieldLimit)
    }

    private static func clamped(_ text: String, toUTF16Units limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let units = character.utf16.count
            if used + units > limit { break }
            result.append(character)
            used += units
        }
        return result
    }
}
