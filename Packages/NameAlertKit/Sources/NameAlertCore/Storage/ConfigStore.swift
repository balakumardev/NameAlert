import Foundation
import os

/// Loads and saves `config.json`.
///
/// Reading never fails and never writes. A missing file gives the defaults. A file that cannot be used (it is
/// unreadable, is not valid JSON, or was written by a newer version of the app) is copied to
/// `config.corrupt-<yyyyMMdd-HHmmss>.json` beside it, so the user's rules are never lost silently, and the defaults
/// are returned. Call `load()` once at startup, before the first `save`.
///
/// Writing is debounced and atomic. `save` keeps only the latest value and writes it once, `debounce` after the
/// first save of a burst; `flush()` writes right away. A failed write is logged, never fatal, and the value stays
/// pending so the next `flush()` tries again.
public actor ConfigStore {
    private let fileURL: URL
    private let debounce: Duration
    private let logger = Log.logger("config")

    /// The newest configuration that is not on disk yet.
    private var pending: AppConfiguration?
    /// Waits out the debounce, then writes `pending`. At most one exists: the first save of a burst starts it and
    /// later saves only replace `pending`.
    private var writeTimer: Task<Void, Never>?

    public init(fileURL: URL = AppPaths.configFile, debounce: Duration = .milliseconds(300)) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    // MARK: Loading

    /// Reads the configuration from disk.
    ///
    /// Returns the defaults, without creating anything, when there is no file. Returns the defaults after setting
    /// the file aside (see the type comment) when it is unreadable, is not valid JSON, or has a `schemaVersion`
    /// newer than `AppConfiguration.currentSchemaVersion`. Anything that does decode is returned as the model
    /// reads it, with defaults for the fields it could not make sense of.
    ///
    /// This is always the file as it is on disk: a `save` that has not been written yet is not included.
    public func load() -> AppConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return AppConfiguration()  // first launch: nothing to load, and nothing to create yet
        } catch {
            return setAside(because: "could not be read (\(error.localizedDescription))")
        }

        do {
            let decoder = JSONDecoder()
            // Ask for the version alone first: a newer file must not be half-read with today's model.
            if let version = try decoder.decode(SchemaProbe.self, from: data).schemaVersion,
               version > AppConfiguration.currentSchemaVersion {
                return setAside(because: "was written by a newer version of NameAlert (schema \(version))")
            }
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            return setAside(because: "is not valid (\(error.localizedDescription))")
        }
    }

    /// Copies the unusable file to a new `config.corrupt-…` file beside it and returns the defaults to start from.
    private func setAside(because reason: String) -> AppConfiguration {
        let backup = Self.backupURL(in: fileURL.deletingLastPathComponent(), date: Date())
        do {
            // copyItem refuses to replace an existing file, so an earlier backup is never overwritten.
            try FileManager.default.copyItem(at: fileURL, to: backup)
            logger.error("""
                config.json \(reason, privacy: .public). Kept a copy as \(backup.lastPathComponent, privacy: .public) \
                and started from defaults.
                """)
        } catch {
            logger.error("""
                config.json \(reason, privacy: .public). Could not keep a copy \
                (\(error.localizedDescription, privacy: .public)); started from defaults.
                """)
        }
        return AppConfiguration()
    }

    /// `config.corrupt-<yyyyMMdd-HHmmss>.json` in `directory`, in local time. If that name is taken, `-1`, `-2`, …
    /// is added before the extension until it is free.
    static func backupURL(in directory: URL, date: Date) -> URL {
        // A fixed format whatever the user's locale or calendar settings are.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "config.corrupt-" + formatter.string(from: date)

        var candidate = directory.appendingPathComponent("\(stem).json", isDirectory: false)
        var suffix = 0
        while FileManager.default.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).json", isDirectory: false)
        }
        return candidate
    }

    // MARK: Saving

    /// Remembers `configuration` as the one to write, and schedules the write if none is scheduled yet.
    ///
    /// The write happens `debounce` after the first save of a burst. Saves that arrive meanwhile only replace the
    /// remembered value, so a burst becomes one write of the last value, and a steady stream of saves still reaches
    /// the disk every `debounce`.
    public func save(_ configuration: AppConfiguration) {
        pending = configuration
        guard writeTimer == nil else { return }  // the running timer will write this value
        writeTimer = Task {
            do {
                try await Task.sleep(for: self.debounce)
            } catch {
                return  // cancelled by flush(), which has already written
            }
            // flush() can also cancel after the sleep ended but before this task got back onto the actor. Then it
            // has written already, and a newer timer may be running, so leave both alone.
            guard !Task.isCancelled else { return }
            self.writeTimer = nil
            self.writePending()
        }
    }

    /// Writes the pending configuration now, if there is one, and cancels the scheduled write.
    public func flush() async {
        writeTimer?.cancel()
        writeTimer = nil
        writePending()
    }

    /// Writes `pending`, if any. It stays pending when the write fails, so the next flush tries again.
    private func writePending() {
        guard let configuration = pending else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            pending = nil
        } catch {
            logger.error("Could not save config.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Reads only `schemaVersion`, so a file from a newer app is recognised before anything else is decoded.
///
/// A missing or malformed value gives `nil`: that is no sign of a newer file, and `AppConfiguration` ignores such a
/// value the same way. A document that is not a JSON object still throws.
private struct SchemaProbe: Decodable {
    let schemaVersion: Int?

    private enum CodingKeys: String, CodingKey { case schemaVersion }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }
}
