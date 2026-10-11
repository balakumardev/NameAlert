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
/// A file that cannot be used (it is unreadable, or is not a valid list of hits) gives an empty history and a line
/// in the log. The file itself is left alone until the next write replaces it. Unlike `config.json`, it is not
/// copied aside first: this is a log, not something the user set up.
///
/// Writing is debounced and atomic. A change schedules one write `debounce` later, unless one is scheduled already,
/// and that write takes the list as it is by then; `flush()` writes right away. A failed write is logged, never
/// fatal, and the change stays unwritten so the next write or `flush()` tries again. Call `flush()` when the app
/// quits or the Mac goes to sleep.
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

    /// The hits in the file, newest first and at most `capacity` of them. Empty, with a line in the log, when the file
    /// cannot be used. Nothing here ever writes.
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return Array(try decoder.decode([Hit].self, from: data).prefix(capacity))
        } catch {
            // The error text is generic ("isn't in the correct format"); it never quotes the file.
            logger.error("""
                history.json is not valid (\(error.localizedDescription, privacy: .public)). \
                Starting with an empty history; the next write replaces the file.
                """)
            return []
        }
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

    /// Empties the history and schedules a write of the empty list. The file is kept, holding an empty array.
    public func clear() {
        hits = []
        isLoaded = true  // whatever the file holds now is about to be replaced, and must not come back
        changed()
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(hits)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            hasUnwrittenChanges = false
        } catch {
            logger.error("Could not save history.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
