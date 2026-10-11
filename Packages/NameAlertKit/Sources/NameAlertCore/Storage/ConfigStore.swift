import Foundation
import os

/// Loads and saves `config.json`.
///
/// Loading never fails, never writes `config.json` and never loses what is in it. A missing file gives the
/// defaults. A file that cannot be used (it is unreadable, is not valid JSON, or was written by a newer version of
/// the app) is kept as `config.corrupt-<yyyyMMdd-HHmmss>.json` beside it, so the user's rules are never lost
/// silently, and the defaults are returned. A file that loads but had rules that could not be read (a rule without
/// a name or terms, or a `rules` that is not a list) is kept the same way, and what could be read is returned. The
/// file is copied; when it cannot be copied (an unreadable file cannot) it is moved instead. If it can be neither
/// copied nor moved, this store never writes, because the next write would replace a file nobody has a copy of.
/// `save` still takes the values and keeps the latest in memory. Call `load()` once at startup, before the first
/// `save`.
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
    /// True when `load()` found a file it could neither copy nor move aside. Nothing is written then, for as long as
    /// this store lives, so that file is never replaced. The values from `save` are kept in memory.
    private(set) var writesAreSuspended = false

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
    /// reads it, with defaults for the fields it could not make sense of; if that dropped rules, the file is kept
    /// as well (see the type comment).
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
            let configuration = try decoder.decode(AppConfiguration.self, from: data)
            if let lost = Self.describeLostRules(in: data, decoded: configuration, decoder: decoder) {
                // What was readable is used, but the next save writes only that: keep the whole file first.
                keepFile(because: lost, andStartFrom: "what could be read")
            }
            return configuration
        } catch {
            return setAside(because: "is not valid (\(error.localizedDescription))")
        }
    }

    /// What was lost from the rules when `decoded` was read from `data`, or `nil` when nothing was: `rules` is
    /// missing, or every entry of it was read.
    private static func describeLostRules(in data: Data, decoded: AppConfiguration, decoder: JSONDecoder) -> String? {
        guard let probe = try? decoder.decode(RulesProbe.self, from: data) else { return nil }
        switch probe.shape {
        case .absent:
            return nil
        case .notAList:
            return "has rules that are not a list, so none were read"
        case .list(let count):
            guard count > decoded.rules.count else { return nil }
            return "has \(count - decoded.rules.count) of its \(count) rules unreadable; the others were kept"
        }
    }

    /// Keeps the unusable file (see `keepFile`) and returns the defaults to start from.
    private func setAside(because reason: String) -> AppConfiguration {
        keepFile(because: reason, andStartFrom: "defaults")
        return AppConfiguration()
    }

    /// Keeps the file the user had as a new `config.corrupt-…` file beside it, so that nothing in it is lost when the
    /// next save replaces it. It is copied; when the copy fails, as it does for an unreadable file, it is moved.
    /// When neither works, writes are suspended so that the file is left as it is.
    private func keepFile(because reason: String, andStartFrom start: String) {
        let directory = fileURL.deletingLastPathComponent()
        let files = FileManager.default
        let copy = Self.backupURL(in: directory, date: Date())
        let copyFailure: any Error
        do {
            // copyItem refuses to replace an existing file, so an earlier backup is never overwritten.
            try files.copyItem(at: fileURL, to: copy)
            logger.error("""
                config.json \(reason, privacy: .public). Kept a copy as \(copy.lastPathComponent, privacy: .public) \
                and started from \(start, privacy: .public).
                """)
            return
        } catch {
            copyFailure = error
            // A copy that stopped halfway is not a backup: take it away so that it is not mistaken for one.
            if files.fileExists(atPath: copy.path) { try? files.removeItem(at: copy) }
        }

        let move = Self.backupURL(in: directory, date: Date())
        do {
            try files.moveItem(at: fileURL, to: move)
            logger.error("""
                config.json \(reason, privacy: .public). It could not be copied \
                (\(copyFailure.localizedDescription, privacy: .public)), so it was moved to \
                \(move.lastPathComponent, privacy: .public) and started from \(start, privacy: .public).
                """)
        } catch {
            writesAreSuspended = true
            logger.error("""
                config.json \(reason, privacy: .public). It could be neither copied \
                (\(copyFailure.localizedDescription, privacy: .public)) nor moved aside \
                (\(error.localizedDescription, privacy: .public)). Changes are not saved until it is dealt with, \
                so that the file is not overwritten.
                """)
        }
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
        guard !writesAreSuspended else { return }  // see `load()`: the value is kept, and nothing is written
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

    /// Writes `pending`, if any. It stays pending when the write fails, so the next flush tries again. Nothing is
    /// written while writes are suspended.
    private func writePending() {
        guard !writesAreSuspended, let configuration = pending else { return }
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

/// Reads only the shape of `rules`, to tell whether decoding the model dropped any: the key is missing, it is not a
/// list, or it is a list of this many entries (of any kind, including the ones the model cannot read).
private struct RulesProbe: Decodable {
    enum Shape: Equatable {
        case absent
        case notAList
        case list(count: Int)
    }

    let shape: Shape

    private enum CodingKeys: String, CodingKey { case rules }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.rules) else {
            shape = .absent
            return
        }
        if let entries = try? container.decode([AnyEntry].self, forKey: .rules) {
            shape = .list(count: entries.count)
        } else {
            shape = .notAList  // includes `null`: there is nothing to read from it
        }
    }
}

/// Accepts any JSON value without looking at it, so that a list of them can be counted.
private struct AnyEntry: Decodable {
    init(from decoder: any Decoder) {}
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
