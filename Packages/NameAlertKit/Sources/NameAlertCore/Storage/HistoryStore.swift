import Foundation
import os

/// Keeps the list of recent hits that the History window shows, in `history.json`.
///
/// The list lives in memory, newest first, and never holds more than `capacity` hits: adding one more drops the
/// oldest. The file is read once, by whichever of `load()`, `all()` or `append` comes first. From then on the list
/// in memory is the truth and the file follows it, so a later `load()` never reads the file over changes that are
/// not written yet, and `append` works without a `load()` before it: an existing history is never replaced by a
/// fresh list. `clear()` needs no read, because it replaces whatever the file holds.
///
/// The file is read entry by entry. An entry that cannot be read as a hit (for example one written by a newer
/// version, with a value this version does not know) is skipped, the others are kept in order, and the number
/// skipped is logged; the next write leaves the skipped entries out of the file. A file that is unreadable, or is
/// not a list at all, gives an empty history and a line in the log, and is left alone until the next write
/// replaces it. Unlike `config.json`, nothing is copied aside first: this is a log, not something the user set up.
///
/// Writing is debounced and atomic. A change schedules one write `debounce` later, unless one is scheduled already,
/// and that write takes the list as it is by then; `flush()` writes right away, and so does `clear()`, because what
/// was cleared must not linger in the file. A failed write is logged, never fatal, and the change stays unwritten
/// so the next write or `flush()` tries again. Call `flush()` when the app quits or the Mac goes to sleep.
///
/// Whether new hits are recorded at all (the history setting) is for the caller to decide; the store keeps what it
/// is given. A hit holds text that was heard, so nothing from a hit is ever logged here.
public actor HistoryStore {
    private let fileURL: URL
    private let capacity: Int
    private let debounce: Duration
    private let logger = Log.logger("history")

    /// The history, newest first and never longer than `capacity`. It stands for the history once `isLoaded`.
    private var hits: [Hit] = []
    /// True once `hits` stands for the history: it was read from the file, or emptied by `clear()`. The file is
    /// never read again after that, so a read can never undo a change that is not written yet.
    private var isLoaded = false
    /// True while `hits` holds a change that is not in the file: not written yet, or its write failed.
    private var hasUnwrittenChanges = false

    /// A short, non-sensitive description (error domain and code) of the last failed write of `history.json`, or
    /// `nil` when the last write succeeded or none has been tried. For the UI to show later.
    public private(set) var lastSaveError: String?
    /// Waits out the debounce, then writes. At most one exists: the first change of a burst starts it, and later
    /// changes only update `hits`.
    private var writeTimer: Task<Void, Never>?

    public init(fileURL: URL = AppPaths.historyFile, capacity: Int = 500, debounce: Duration = .seconds(1)) {
        self.fileURL = fileURL
        self.capacity = max(capacity, 0)  // a negative capacity would crash the trimming; it means "keep nothing"
        self.debounce = debounce
    }

    // MARK: Reading

    /// The history, newest first.
    ///
    /// The first of `load()`, `all()` and `append` reads the file. This and every later call return the list in
    /// memory, including changes that are not written yet, and never write anything themselves. With no file (not
    /// even its folder), the history is empty and nothing is created. A file that holds more than `capacity` hits
    /// gives the newest ones.
    public func load() -> [Hit] {
        loadIfNeeded()
        return hits
    }

    /// The same list as `load()`.
    public func all() -> [Hit] {
        loadIfNeeded()
        return hits
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        hits = readFile()
    }

    /// The hits in the file, newest first and at most `capacity` of them. Entries that cannot be read are left out
    /// (and counted in the log); an empty list, with a line in the log, when the file cannot be used at all.
    /// Nothing here ever writes.
    private func readFile() -> [Hit] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []  // first launch: nothing to load, and nothing to create yet
        } catch {
            logger.error("""
                history.json could not be read (\(error.localizedDescription, privacy: .public)). \
                Starting with an empty history; the next write replaces the file.
                """)
            return []
        }

        do {
            let decoded = try Self.decodeHits(from: data)
            if decoded.skipped > 0 {
                // Only the count: an entry that failed to decode may hold anything that was heard.
                logger.error("""
                    history.json has entries that could not be read, for example hits written by a newer version \
                    of \(AppName.current, privacy: .public). Skipped: \(decoded.skipped, privacy: .public). The \
                    others were kept; the next write leaves the skipped ones out of the file.
                    """)
            }
            return Array(decoded.hits.prefix(capacity))
        } catch {
            // The error text is generic ("isn't in the correct format"); it never quotes the file.
            logger.error("""
                history.json is not valid (\(error.localizedDescription, privacy: .public)). \
                Starting with an empty history; the next write replaces the file.
                """)
            return []
        }
    }

    /// The hits in `data`, in file order, and how many entries were skipped because they could not be read as a hit.
    /// Throws only when `data` is not a JSON list at all. (Internal, so that tests can reach the skipped count.)
    static func decodeHits(from data: Data) throws -> (hits: [Hit], skipped: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = HistoryTimestamp.date(from: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date.")
            }
            return date
        }
        let entries = try decoder.decode([Lossy<Hit>].self, from: data)
        let hits = entries.compactMap(\.element)
        return (hits, entries.count - hits.count)
    }

    // MARK: Changing

    /// Puts `hit` at the front, drops the oldest hits beyond `capacity`, and schedules a write.
    public func append(_ hit: Hit) {
        loadIfNeeded()
        hits.insert(hit, at: 0)
        if hits.count > capacity {
            hits.removeLast(hits.count - capacity)
        }
        changed()
    }

    /// Empties the history and writes the empty list at once, not after the debounce: what was cleared must not
    /// linger in the file. A write that was waiting is cancelled, as this one replaces it. The file is kept, holding
    /// an empty array. If the write fails, it is tried again after the debounce, like any other.
    public func clear() {
        hits = []
        isLoaded = true  // whatever the file holds now is about to be replaced, and must not come back
        hasUnwrittenChanges = true
        writeTimer?.cancel()
        writeTimer = nil
        writeIfNeeded()
        if hasUnwrittenChanges { changed() }
    }

    // MARK: Writing

    /// Notes that the file is behind `hits`, and starts the timer that writes it unless a timer is running already.
    ///
    /// The write happens `debounce` after the first change of a burst. Changes that arrive meanwhile only update
    /// `hits`, so a burst becomes one write of the final list, and a steady stream of changes still reaches the disk
    /// every `debounce`.
    private func changed() {
        hasUnwrittenChanges = true
        guard writeTimer == nil else { return }  // the running timer will write this change too
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
            self.writeIfNeeded()
        }
    }

    /// Writes any change that is not in the file yet, now, and cancels the scheduled write.
    public func flush() async {
        writeTimer?.cancel()
        writeTimer = nil
        writeIfNeeded()
    }

    /// Writes `hits` if the file is behind it. The change stays unwritten when the write fails, so the next write
    /// or flush tries again.
    private func writeIfNeeded() {
        guard hasUnwrittenChanges else { return }
        do {
            let data = try Self.encode(hits)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            hasUnwrittenChanges = false
            lastSaveError = nil
        } catch {
            let ns = error as NSError
            lastSaveError = "\(ns.domain) \(ns.code)"
            logger.error("Could not save history.json (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The file's contents for `hits`: a compact JSON list with sorted keys. (Internal, so tests can build files.)
    static func encode(_ hits: [Hit]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HistoryTimestamp.string(from: date))
        }
        return try encoder.encode(hits)
    }
}
