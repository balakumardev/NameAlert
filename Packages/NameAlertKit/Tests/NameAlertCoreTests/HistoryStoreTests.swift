import Foundation
@testable import NameAlertCore
import Testing

@Suite("HistoryStore")
struct HistoryStoreTests {
    // MARK: Helpers

    /// A debounce so long that only `flush()` ever writes, for tests that decide for themselves when to write.
    private let neverByItself: Duration = .seconds(3600)

    /// Runs `body` with a fresh, empty directory under the system temp folder and removes it afterwards.
    /// Every test points its store at a file inside such a directory, never at the real Application Support folder.
    private func inTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// A hit that differs from every other `makeHit` result: its own id, texts, source and engine.
    ///
    /// The timestamp is a whole second unless `timestamp` says otherwise. A hit read back from the file compares
    /// equal to the one that was stored as long as its timestamp is a whole number of milliseconds.
    private func makeHit(_ number: Int, timestamp: Date? = nil) -> Hit {
        Hit(
            ruleID: UUID(), ruleName: "Rule \(number)", term: "term \(number)", matchedText: "matched \(number)",
            context: "context \(number)",
            timestamp: timestamp ?? Date(timeIntervalSince1970: 1_700_000_000 + Double(number)),
            source: AudioSourceKind.allCases[number % AudioSourceKind.allCases.count],
            engine: EngineID.allCases[number % EngineID.allCases.count],
            segmentID: "segment-\(number)"
        )
    }

    /// What is on disk right now, decoded without going through a store instance.
    private func readHistory(at url: URL) throws -> [Hit] {
        try HistoryStore.decodeHits(from: Data(contentsOf: url)).hits
    }

    /// The JSON object the store writes for `hit`, to build files by hand.
    private func entry(for hit: Hit) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: HistoryStore.encode([hit]))
        let list = try #require(object as? [[String: Any]])
        return try #require(list.first)
    }

    /// A history file holding `entries`, in that order.
    private func fileData(_ entries: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entries, options: .sortedKeys)
    }

    /// The file system's number for the file at `url`; a different number means a different file.
    private func fileNumber(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    /// Polls until `condition` holds or `timeout` passes. Returns whether it held.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Order and capacity

    @Test func appendNewestFirst() async throws {
        try await inTemporaryDirectory { directory in
            let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), debounce: neverByItself)
            let h1 = makeHit(1)
            let h2 = makeHit(2)
            await store.append(h1)
            await store.append(h2)

            let all = await store.all()
            #expect(all == [h2, h1])
            await store.flush()
        }
    }

    @Test func capacityDropsOldest() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: file, debounce: neverByItself)  // the default capacity: 500
            let hits = (1...501).map { makeHit($0) }
            for hit in hits {
                await store.append(hit)
            }

            let all = await store.all()
            #expect(all.count == 500)
            #expect(!all.contains(hits[0]))  // the first one appended is the one that went
            #expect(all == Array(hits.dropFirst().reversed()))  // the other 500, newest first

            // The file holds the same 500, and a new store reads the same 500 back.
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == all)
            let reloaded = await HistoryStore(fileURL: file).load()
            #expect(reloaded == all)
        }
    }

    @Test func smallerCapacityKeepsTheNewest() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: file, capacity: 3, debounce: neverByItself)
            let hits = (1...5).map { makeHit($0) }
            for hit in hits {
                await store.append(hit)
            }
            let all = await store.all()
            #expect(all == [hits[4], hits[3], hits[2]])
            await store.flush()
        }
    }

    @Test func loadKeepsOnlyTheNewestWhenTheFileHoldsMoreThanTheCapacity() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hits = (1...5).map { makeHit($0) }
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            for hit in hits {
                await writer.append(hit)
            }
            await writer.flush()

            // The same file opened by a store that holds fewer, for example after a smaller capacity was chosen.
            let store = HistoryStore(fileURL: file, capacity: 3, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded == [hits[4], hits[3], hits[2]])

            // And it stays at three from here on.
            let sixth = makeHit(6)
            await store.append(sixth)
            let all = await store.all()
            #expect(all == [sixth, hits[4], hits[3]])
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == all)
        }
    }

    @Test(arguments: [0, -1, Int.min])
    func aCapacityBelowOneKeepsNothingAndDoesNotCrash(capacity: Int) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            await writer.append(makeHit(1))
            await writer.flush()

            let store = HistoryStore(fileURL: file, capacity: capacity, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded.isEmpty)
            await store.append(makeHit(2))
            let all = await store.all()
            #expect(all.isEmpty)
            await store.flush()
        }
    }

    // MARK: Clearing

    @Test func clearEmpties() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(makeHit(1))
            await store.append(makeHit(2))
            await store.clear()
            let afterClear = await store.all()
            #expect(afterClear.isEmpty)

            // The empty list is written as an empty array. The file is kept, not removed.
            await store.flush()
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(text == "[]")
            let reloaded = await HistoryStore(fileURL: file).load()
            #expect(reloaded.isEmpty)

            // The store keeps working after a clear.
            let h3 = makeHit(3)
            await store.append(h3)
            let again = await store.all()
            #expect(again == [h3])
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [h3])
        }
    }

    @Test func clearIsNotUndoneByALaterLoadAndWorksBeforeAnyLoad() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hit = makeHit(1)
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            await writer.append(hit)
            await writer.flush()

            // clear() as the very first call: nothing was loaded, and the old file must not come back.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.clear()
            let loaded = await store.load()
            #expect(loaded.isEmpty)
            let all = await store.all()
            #expect(all.isEmpty)

            // Like every change, the empty list reaches the file on flush (or the debounce), not before.
            let beforeFlush = try readHistory(at: file)
            #expect(beforeFlush == [hit])
            await store.flush()
            let afterFlush = try readHistory(at: file)
            #expect(afterFlush.isEmpty)
        }
    }

    // MARK: Loading

    @Test func persistsAcrossInstances() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hits = (1...3).map { makeHit($0) }  // three sources and three engines between them
            let first = HistoryStore(fileURL: file, debounce: neverByItself)
            for hit in hits {
                await first.append(hit)
            }
            await first.flush()

            let second = HistoryStore(fileURL: file)
            let loaded = await second.load()
            #expect(loaded == [hits[2], hits[1], hits[0]])
            let all = await second.all()
            #expect(all == loaded)
        }
    }

    @Test(arguments: [
        Data(),
        Data("   \n".utf8),
        Data("{not json".utf8),
        Data("[{\"id\": \"ab".utf8),  // cut off in the middle of a hit
        Data("[] trailing".utf8),
        Data(#"{"hits":[]}"#.utf8),  // an object, not a list
        Data("null".utf8),
        Data("42".utf8),
        Data(#""text""#.utf8),
        Data("[1, 2]".utf8),  // a list, but not of hits
        Data(#"[{"id":"not-a-uuid"}]"#.utf8),  // looks like a hit, but is missing everything else
        Data([0xFF, 0x00, 0xFF, 0x80]),
    ])
    func corruptFileLoadsEmpty(original: Data) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            try original.write(to: file)

            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded.isEmpty)
            let all = await store.all()
            #expect(all.isEmpty)

            // Reading leaves the file exactly as it was: no rewrite, no backup, nothing else beside it.
            let afterLoad = try Data(contentsOf: file)
            #expect(afterLoad == original)
            let beside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(beside == ["history.json"])

            // The next write replaces it with a good file. History is not worth a backup.
            let hit = makeHit(1)
            await store.append(hit)
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [hit])
            let besideAfter = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(besideAfter == ["history.json"])
        }
    }

    @Test func badHistoryElementIsSkipped() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let valid1 = makeHit(1)
            let valid2 = makeHit(2)

            // A real file, written by a store and then edited into what a newer app version could leave behind: an
            // entry that is no hit at all, and a hit with an engine this version has never heard of.
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            await writer.append(valid2)
            await writer.append(valid1)
            await writer.flush()
            let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let entries = try #require(written as? [[String: Any]])
            try #require(entries.count == 2)
            var futureEngine = entries[0]
            futureEngine["engine"] = "futureEngine"
            let edited: [Any] = [entries[0], ["garbage": true], futureEngine, entries[1]]
            let editedData = try JSONSerialization.data(withJSONObject: edited)
            try editedData.write(to: file)

            // The two bad entries are skipped and the two good ones stay, in order.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded == [valid1, valid2])
            let afterLoad = try Data(contentsOf: file)
            #expect(afterLoad == editedData)  // reading never rewrites the file

            // The next write is the first time the skipped entries leave the file.
            let valid3 = makeHit(3)
            await store.append(valid3)
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [valid3, valid1, valid2])
        }
    }

    /// Ways one entry of the list can be unreadable. A newer version that writes a value this one does not know
    /// (`unknownEngine`, `unknownSource`) is the realistic one; the rest is hand edits and damage.
    enum BadEntry: String, CaseIterable, CustomTestStringConvertible {
        case null, number, text, emptyList, emptyObject, unrelatedObject
        case unknownEngine, unknownSource, notAUUID, notADate, dateAsNumber, missingContext, contextNotText

        var testDescription: String { rawValue }

        /// `valid` broken in this way, or just the broken value for entries that are not a hit at all.
        func make(from valid: [String: Any]) -> Any {
            var broken = valid
            switch self {
            case .null: return NSNull()
            case .number: return 42
            case .text: return "text"
            case .emptyList: return [Any]()
            case .emptyObject: return [String: Any]()
            case .unrelatedObject: return ["garbage": true]
            case .unknownEngine: broken["engine"] = "futureEngine"
            case .unknownSource: broken["source"] = "futureSource"
            case .notAUUID: broken["id"] = "not-a-uuid"
            case .notADate: broken["timestamp"] = "yesterday"
            case .dateAsNumber: broken["timestamp"] = 781_867_800.123
            case .missingContext: broken["context"] = nil
            case .contextNotText: broken["context"] = 42
            }
            return broken
        }
    }

    @Test(arguments: BadEntry.allCases)
    func everyKindOfBadEntryIsSkipped(bad: BadEntry) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let valid1 = makeHit(1)
            let valid2 = makeHit(2)
            let good1 = try entry(for: valid1)
            let good2 = try entry(for: valid2)
            // The bad entry starts from a copy of the first hit, so it would show up as a duplicate if it loaded.
            let data = try fileData([good1, bad.make(from: good1), good2])
            try data.write(to: file)

            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded == [valid1, valid2])
            let decoded = try HistoryStore.decodeHits(from: data)
            #expect(decoded.skipped == 1)
        }
    }

    @Test func skippedEntriesAreCounted() throws {
        let h1 = makeHit(1)
        let h2 = makeHit(2)
        let good1 = try entry(for: h1)
        let good2 = try entry(for: h2)

        let clean = try HistoryStore.decodeHits(from: fileData([good1, good2]))
        #expect(clean.hits == [h1, h2])
        #expect(clean.skipped == 0)

        let empty = try HistoryStore.decodeHits(from: fileData([]))
        #expect(empty.hits.isEmpty)
        #expect(empty.skipped == 0)

        let mixed = try HistoryStore.decodeHits(from: fileData([NSNull(), good1, ["garbage": true], 7, good2]))
        #expect(mixed.hits == [h1, h2])
        #expect(mixed.skipped == 3)

        let allBad = try HistoryStore.decodeHits(from: Data("[1, 2, 3]".utf8))
        #expect(allBad.hits.isEmpty)
        #expect(allBad.skipped == 3)

        // Not a list at all is damage to the whole file, not to an entry, and it still throws.
        #expect(throws: (any Error).self) { try HistoryStore.decodeHits(from: Data(#"{"hits":[]}"#.utf8)) }
    }

    @Test(.enabled(if: getuid() != 0, "root can read any file"))
    func unreadableFileLoadsEmptyAndIsLeftAlone() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let original = Data("[]".utf8)
            try original.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            // Some file systems ignore permission bits. Then there is nothing to test.
            guard !FileManager.default.isReadableFile(atPath: file.path) else { return }

            // The OS refuses the read. Nothing crashes, the history is empty, and the file stays as it was.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded.isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            let afterLoad = try Data(contentsOf: file)
            #expect(afterLoad == original)
        }
    }

    @Test func appendBeforeLoadKeepsExistingHistory() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let h1 = makeHit(1)
            let h2 = makeHit(2)
            let h3 = makeHit(3)
            let earlier = HistoryStore(fileURL: file, debounce: neverByItself)
            await earlier.append(h1)
            await earlier.append(h2)
            await earlier.flush()

            // A store whose very first call is append(): it reads the file first instead of starting a fresh list.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(h3)
            let all = await store.all()
            #expect(all == [h3, h2, h1])
            let loaded = await store.load()  // and a load() after that is the same list, not a second read
            #expect(loaded == [h3, h2, h1])

            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [h3, h2, h1])
            let reloaded = await HistoryStore(fileURL: file).load()
            #expect(reloaded == [h3, h2, h1])
        }
    }

    @Test func allReadsTheFileWhenItIsTheFirstCall() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let h1 = makeHit(1)
            let h2 = makeHit(2)
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            await writer.append(h1)
            await writer.append(h2)
            await writer.flush()

            // Nobody called load(): all() must still show the history, not an empty list.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let all = await store.all()
            #expect(all == [h2, h1])
        }
    }

    @Test func loadReadsTheFileOnlyOnceSoPendingChangesAreNeverLost() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let h1 = makeHit(1)
            let h2 = makeHit(2)
            let writer = HistoryStore(fileURL: file, debounce: neverByItself)
            await writer.append(h1)
            await writer.flush()

            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let first = await store.load()
            #expect(first == [h1])

            // h2 is only in memory. Asking for the history again must not go back to the file and drop it.
            await store.append(h2)
            let second = await store.load()
            #expect(second == [h2, h1])
            let stillOnDisk = try readHistory(at: file)
            #expect(stillOnDisk == [h1])  // and loading did not write it either

            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [h2, h1])
        }
    }

    @Test func loadAndFlushWithNothingPendingWriteNothing() async throws {
        try await inTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("NameAlert", isDirectory: true)
            let file = folder.appendingPathComponent("history.json")

            // First launch: neither the file nor its folder exists. Loading and flushing create neither.
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            let loaded = await store.load()
            #expect(loaded.isEmpty)
            await store.flush()
            #expect(!exists(folder))

            let hit = makeHit(1)
            await store.append(hit)
            await store.flush()
            let writtenFile = try fileNumber(of: file)

            // A file that is there is not rewritten just because it was read, or flushed.
            let reader = HistoryStore(fileURL: file, debounce: neverByItself)
            let reloaded = await reader.load()
            #expect(reloaded == [hit])
            await reader.flush()
            let afterReader = try fileNumber(of: file)
            #expect(afterReader == writtenFile)

            // Already written, so a second flush has nothing to do.
            try FileManager.default.removeItem(at: file)
            await store.flush()
            #expect(!exists(file))
        }
    }

    // MARK: Writing

    @Test func appendsWaitForTheDebounceOrAFlush() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hit = makeHit(1)

            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(hit)
            #expect(!exists(file))  // deferred: nothing is on disk when append returns
            try await Task.sleep(for: .milliseconds(150))
            #expect(!exists(file))  // and the timer does not write earlier than the debounce says

            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [hit])
        }
    }

    @Test func timerWritesTheLatestStateOnceWithoutFlush() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hits = (1...3).map { makeHit($0) }
            let newestFirst = [hits[2], hits[1], hits[0]]

            let store = HistoryStore(fileURL: file, debounce: .milliseconds(300))
            for hit in hits {
                await store.append(hit)
            }

            // Nobody flushes. The timer started by the first append writes the file by itself, with all three.
            let written = await waitUntil { (try? readHistory(at: file)) == newestFirst }
            #expect(written)

            // The burst produced a single write: once the file is removed, nothing brings it back.
            try FileManager.default.removeItem(at: file)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!exists(file))

            // And the timer slot was released, so a later append is written too.
            let later = makeHit(4)
            await store.append(later)
            let writtenAgain = await waitUntil { (try? readHistory(at: file)) == [later] + newestFirst }
            #expect(writtenAgain)
        }
    }

    @Test func aSteadyStreamStillReachesTheDisk() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: file, debounce: .milliseconds(300))

            // A hit every 40 ms, far faster than the debounce. The write comes `debounce` after the first hit of the
            // stream. It is not pushed back by each new hit, which would keep it from ever happening.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var number = 0
            while !exists(file), clock.now < deadline {
                number += 1
                await store.append(makeHit(number))
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(exists(file))
            await store.flush()
        }
    }

    @Test func afterFlushNothingIsWrittenAgainAndLaterAppendsStillWork() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let first = makeHit(1)
            let store = HistoryStore(fileURL: file, debounce: .milliseconds(200))
            await store.append(first)
            await store.flush()
            #expect(exists(file))

            // The timer that was waiting when flush() ran must not write a second time ...
            try FileManager.default.removeItem(at: file)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!exists(file))

            // ... and flush() leaves the store able to schedule the next write.
            let second = makeHit(2)
            await store.append(second)
            let written = await waitUntil { (try? readHistory(at: file)) == [second, first] }
            #expect(written)
        }
    }

    @Test func flushCancelsTheTimerSoNothingKeepsTheStoreAlive() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            weak var weakStore: HistoryStore?
            do {
                let store = HistoryStore(fileURL: file, debounce: .seconds(3600))
                weakStore = store
                await store.append(makeHit(1))
                await store.flush()
            }
            // The timer holds on to its store. One still waiting out an hour would keep it alive; a cancelled one
            // lets go at once.
            let released = await waitUntil { weakStore == nil }
            #expect(released)
        }
    }

    @Test func pendingWriteSurvivesTheStoreBeingReleased() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hit = makeHit(1)
            do {
                let store = HistoryStore(fileURL: file, debounce: .milliseconds(100))
                await store.append(hit)
            }
            // Nobody holds the store any more, but its timer does until the write is done.
            let written = await waitUntil { (try? readHistory(at: file)) == [hit] }
            #expect(written)
        }
    }

    @Test func writeCreatesTheFolderAndUsesCompactSortedISO8601JSON() async throws {
        try await inTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("Library/NameAlert", isDirectory: true)
            let file = folder.appendingPathComponent("history.json")
            #expect(!exists(folder))

            let hit = makeHit(1)  // timestamp 1 700 000 001, which is 2023-11-14 22:13:21 UTC
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(hit)
            await store.flush()

            // An atomic write leaves no temporary file behind.
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(names == ["history.json"])

            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(text.hasPrefix(#"[{"context":"#))  // a list of objects, written compactly
            #expect(text.hasSuffix("}]"))
            #expect(!text.contains("\n"))
            #expect(text.contains(#""timestamp":"2023-11-14T22:13:21.000Z""#))  // UTC, always three fraction digits
            let keys = [
                "context", "engine", "id", "matchedText", "ruleID", "ruleName", "segmentID", "source", "term",
                "timestamp",
            ]
            let positions = keys.map { text.range(of: "\"\($0)\":")?.lowerBound }
            #expect(!positions.contains { $0 == nil }, "every field is written")
            let offsets = positions.compactMap { $0 }.map { text.distance(from: text.startIndex, to: $0) }
            #expect(offsets == offsets.sorted(), "keys are sorted")

            let onDisk = try readHistory(at: file)
            #expect(onDisk == [hit])
        }
    }

    @Test func fractionalTimestampsSurviveReload() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let hit = makeHit(1, timestamp: Date(timeIntervalSince1970: 1_760_175_000.123))
            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(hit)
            await store.flush()

            // Through the file and back, the hit is equal to the one that was stored, to the last bit of the date.
            let reloaded = await HistoryStore(fileURL: file).load()
            #expect(reloaded == [hit])
            #expect(reloaded.first?.timestamp == hit.timestamp)
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(text.contains(#""timestamp":"2025-10-11T09:30:00.123Z""#))
        }
    }

    @Test func wholeSecondTimestampsStillLoad() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let h1 = makeHit(1)  // 2023-11-14 22:13:21 UTC
            let h2 = makeHit(2)

            // The form without a fraction, which is what this file held before milliseconds were added.
            var first = try entry(for: h1)
            var second = try entry(for: h2)
            first["timestamp"] = "2023-11-14T22:13:21Z"
            second["timestamp"] = "2023-11-14T22:13:22Z"
            try fileData([first, second]).write(to: file)

            let loaded = await HistoryStore(fileURL: file).load()
            #expect(loaded == [h1, h2])
        }
    }

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

    @Test func rewriteReplacesTheFileInsteadOfEditingItInPlace() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let store = HistoryStore(fileURL: file, debounce: neverByItself)

            await store.append(makeHit(1))
            await store.flush()
            let firstFile = try fileNumber(of: file)

            let second = makeHit(2)
            await store.append(second)
            await store.flush()

            // An atomic write goes to a temporary file that is then renamed over the old one, so a crash or a full
            // disk halfway through leaves the previous history intact. The file number changing is how that shows.
            let secondFile = try fileNumber(of: file)
            #expect(secondFile != firstFile)
            let onDisk = try readHistory(at: file)
            #expect(onDisk.first == second)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names == ["history.json"])
        }
    }

    // MARK: Failures

    @Test func failedWriteIsSurvivedAndRetried() async throws {
        try await inTemporaryDirectory { directory in
            // A plain file where the history folder should be: the folder cannot be created.
            let blocker = directory.appendingPathComponent("blocker")
            let blockerContents = Data("not a folder".utf8)
            try blockerContents.write(to: blocker)
            let file = blocker.appendingPathComponent("history.json")
            let hit = makeHit(1)

            let store = HistoryStore(fileURL: file, debounce: neverByItself)
            await store.append(hit)
            await store.flush()  // fails and logs; it must neither crash nor touch the file in the way
            let blockerAfter = try Data(contentsOf: blocker)
            #expect(blockerAfter == blockerContents)
            let inMemory = await store.all()
            #expect(inMemory == [hit])  // and the hit is still there

            // The change was kept, so the next flush writes it once the path is usable.
            try FileManager.default.removeItem(at: blocker)
            await store.flush()
            let onDisk = try readHistory(at: file)
            #expect(onDisk == [hit])
        }
    }

    @Test func aFailedTimedWriteDoesNotStopLaterAppendsFromBeingWritten() async throws {
        try await inTemporaryDirectory { directory in
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a folder".utf8).write(to: blocker)
            let file = blocker.appendingPathComponent("history.json")
            let first = makeHit(1)
            let second = makeHit(2)

            let store = HistoryStore(fileURL: file, debounce: .milliseconds(50))
            await store.append(first)
            try await Task.sleep(for: .milliseconds(300))  // the timer fires and the write fails
            #expect(!exists(file))

            // The timer slot is free again, so the next append schedules a new write, and that write carries both.
            try FileManager.default.removeItem(at: blocker)
            await store.append(second)
            let written = await waitUntil { (try? readHistory(at: file)) == [second, first] }
            #expect(written)
        }
    }

    // MARK: Interleaving

    @Test(arguments: [Duration.seconds(3600), .milliseconds(1), .zero])
    func interleavedAppendClearAndFlushLoseNothing(debounce: Duration) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            let capacity = 5
            // With the long debounce only flush() writes. With the short ones the timer writes in between as well,
            // racing with the next call; flush() must still leave the file equal to what the store holds.
            let store = HistoryStore(fileURL: file, capacity: capacity, debounce: debounce)
            var generator = SeededGenerator(state: 20_261_011)
            var model: [Hit] = []  // what the store must hold: the same operations on a plain array
            var touched = false
            var number = 0

            for step in 0..<400 {
                switch Int.random(in: 0..<10, using: &generator) {
                case 0..<6:
                    number += 1
                    let hit = makeHit(number)
                    await store.append(hit)
                    model = Array(([hit] + model).prefix(capacity))
                    touched = true
                case 6, 7:
                    await store.clear()
                    model = []
                    touched = true
                default:
                    await store.flush()
                    if touched {
                        #expect(exists(file), "step \(step): flushed, so the file must exist")
                        let onDisk = try readHistory(at: file)
                        #expect(onDisk == model, "step \(step): the file after a flush")
                    }
                }
                let all = await store.all()
                #expect(all == model, "step \(step): the store")
            }

            await store.flush()
            if touched {
                let reloaded = await HistoryStore(fileURL: file, capacity: capacity).load()
                #expect(reloaded == model)
            }
        }
    }

    @Test func concurrentAppendsAreAllKept() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("history.json")
            // A short debounce, so timer writes happen while the appends are still arriving, and flushes from other
            // tasks land in between.
            let store = HistoryStore(fileURL: file, debounce: .milliseconds(5))
            let hits = (1...200).map { makeHit($0) }
            await withTaskGroup(of: Void.self) { group in
                for (index, hit) in hits.enumerated() {
                    group.addTask { await store.append(hit) }
                    if index.isMultiple(of: 10) {
                        group.addTask { await store.flush() }
                    }
                }
            }

            await store.flush()
            let all = await store.all()
            #expect(all.count == 200)
            #expect(Set(all.map(\.id)) == Set(hits.map(\.id)))
            let onDisk = try readHistory(at: file)
            #expect(onDisk == all)
        }
    }
}

/// A small deterministic generator (SplitMix64), so a failing run can be repeated exactly.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
