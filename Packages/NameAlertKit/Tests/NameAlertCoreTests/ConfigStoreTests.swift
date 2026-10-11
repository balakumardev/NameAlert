import Foundation
@testable import NameAlertCore
import Testing

@Suite("ConfigStore")
struct ConfigStoreTests {
    // MARK: Helpers

    /// Runs `body` with a fresh, empty directory under the system temp folder and removes it afterwards.
    /// Every test points its store at a file inside such a directory, never at the real Application Support folder.
    private func inTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// A debounce that never runs out during a test, for the tests that only look at what `load()` leaves on disk.
    /// After a backup `load()` schedules a save. A short debounce would let it write between two of a test's checks,
    /// or into the test's folder after the test has removed it.
    private let neverWithinATest = Duration.seconds(3600)

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The quarantined copies in `directory`, i.e. everything named like `config.corrupt-*.json`.
    private func backups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("config.corrupt-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// What is on disk right now, decoded without going through a store.
    private func readConfiguration(at url: URL) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
    }

    /// The file system's number for the file at `url`; a different number means a different file.
    private func fileNumber(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try #require(attributes[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    /// A configuration that differs from the defaults and from any other `ruleNamed:` value (rule ids are random).
    private func makeConfiguration(ruleNamed name: String) -> AppConfiguration {
        var config = AppConfiguration()
        config.rules = [Rule(name: name, terms: [name.lowercased()])]
        return config
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

    // MARK: Loading

    @Test func missingFileLoadsDefaults() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded == AppConfiguration())
            // Loading only reads: no config.json, and no backup or anything else, appears.
            #expect(!exists(file))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(leftovers.isEmpty)

            // Same on a first launch, when the whole folder is missing: it is not created either.
            let nested = directory.appendingPathComponent("NameAlert/config.json")
            let loadedFromMissingFolder = await ConfigStore(fileURL: nested).load()
            #expect(loadedFromMissingFolder == AppConfiguration())
            #expect(!exists(nested.deletingLastPathComponent()))
        }
    }

    @Test func readableFilesAreNotBackedUp() async throws {
        // Fields that decode tolerantly are the model's business. The store only sets aside what cannot be used.
        let cases: [(json: String, ruleNames: [String])] = [
            ("{}", []),
            (#"{"rules":[]}"#, []),
            (#"{"schemaVersion":1,"rules":[{"name":"keep","terms":["k"]}]}"#, ["keep"]),
            (#"{"listening":{"source":"radio"},"rules":[{"name":"keep","terms":["k"]}]}"#, ["keep"]),
        ]
        for (json, ruleNames) in cases {
            try await inTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("config.json")
                try Data(json.utf8).write(to: file)
                let loaded = await ConfigStore(fileURL: file).load()
                #expect(loaded.rules.map(\.name) == ruleNames, "\(json)")
                #expect(loaded.listening.source == .systemAudio, "\(json)")
                #expect(try backups(in: directory).isEmpty, "\(json)")
            }
        }
    }

    // MARK: Corrupt and newer files

    @Test func corruptFileIsBackedUp() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("{not json".utf8)
            try original.write(to: file)

            let loaded = await ConfigStore(fileURL: file, debounce: neverWithinATest).load()
            #expect(loaded == AppConfiguration())

            let found = try backups(in: directory)
            #expect(found.count == 1)
            let backup = try #require(found.first)
            #expect(try Data(contentsOf: backup) == original)
            let name = backup.lastPathComponent
            let pattern = #"^config\.corrupt-\d{8}-\d{6}\.json$"#
            #expect(name.range(of: pattern, options: .regularExpression) != nil, "\(name)")
            // The file is only copied: loading never deletes or rewrites what the user had.
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test(arguments: [
        Data(),
        Data("   \n".utf8),
        Data(#"{"rules": ["#.utf8),
        Data(#"{"rules":[]} trailing"#.utf8),
        Data("[1, 2]".utf8),
        Data("null".utf8),
        Data("42".utf8),
        Data(#""text""#.utf8),
        Data([0xFF, 0x00, 0xFF, 0x80]),
    ])
    func otherUnusableFilesAreBackedUp(original: Data) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try original.write(to: file)

            let loaded = await ConfigStore(fileURL: file, debounce: neverWithinATest).load()
            #expect(loaded == AppConfiguration())

            let found = try backups(in: directory)
            #expect(found.count == 1)
            let backup = try #require(found.first)
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    @Test(.enabled(if: getuid() != 0, "root can read any file"))
    func unreadableFileIsMovedAside() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data(#"{"rules":[{"name":"keep","terms":["k"]}]}"#.utf8)
            try original.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            // Some file systems ignore permission bits. Then there is nothing to test.
            guard !FileManager.default.isReadableFile(atPath: file.path) else { return }

            // The OS refuses the read, and so the copy for the backup. A file can still be renamed, which keeps the
            // user's bytes: the file is moved aside, the defaults load, and the store is free to write a new config.
            let store = ConfigStore(fileURL: file, debounce: neverWithinATest)
            let loaded = await store.load()
            #expect(loaded == AppConfiguration())
            #expect(!exists(file))
            let found = try backups(in: directory)
            #expect(found.count == 1)
            let backup = try #require(found.first)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
            #expect(try Data(contentsOf: backup) == original)
            let suspended = await store.writesAreSuspended
            #expect(!suspended)

            let config = makeConfiguration(ruleNamed: "x")
            await store.save(config)
            await store.flush()
            #expect(try readConfiguration(at: file) == config)
            #expect(try Data(contentsOf: backup) == original)  // and the moved file is not touched by it
        }
    }

    @Test(.enabled(if: getuid() != 0, "root ignores folder permissions"))
    func failedBackupSuspendsWrites() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("{not json".utf8)
            try original.write(to: file)
            // A folder nothing can be added to: the copy has no room, and the file cannot be renamed inside it.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
            guard !FileManager.default.isWritableFile(atPath: directory.path) else { return }

            let store = ConfigStore(fileURL: file, debounce: .milliseconds(10))
            let loaded = await store.load()
            #expect(loaded == AppConfiguration())
            let suspended = await store.writesAreSuspended
            #expect(suspended)

            // The folder can be written again by now, so only the store's own choice keeps the file as it is: nobody
            // has a copy of it, and a write would replace it.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            await store.save(makeConfiguration(ruleNamed: "x"))
            try await Task.sleep(for: .milliseconds(150))  // far longer than the debounce
            await store.flush()
            #expect(try Data(contentsOf: file) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
        }
    }

    @Test func goodFilesDoNotSuspendWrites() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            for original in [nil, Data("{not json".utf8), Data(#"{"rules":"oops"}"#.utf8)] {
                if let original { try original.write(to: file) } else { try? FileManager.default.removeItem(at: file) }
                let store = ConfigStore(fileURL: file, debounce: .milliseconds(10))
                _ = await store.load()
                let suspended = await store.writesAreSuspended
                #expect(!suspended, "\(original.map { String(decoding: $0, as: UTF8.self) } ?? "no file")")
                let config = makeConfiguration(ruleNamed: "x")
                await store.save(config)
                await store.flush()
                #expect(try readConfiguration(at: file) == config)
            }
        }
    }

    @Test(arguments: [
        #"{"rules":"oops","listening":{"source":"microphone"}}"#,
        #"{"rules":{"name":"a","terms":["x"]},"listening":{"source":"microphone"}}"#,
        #"{"rules":null,"listening":{"source":"microphone"}}"#,
        #"{"rules":7,"listening":{"source":"microphone"}}"#,
    ])
    func rulesNotArrayIsBackedUp(json: String) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data(json.utf8)
            try original.write(to: file)

            // The rest of the file loads, but the next save would leave out whatever `rules` held: it is kept first.
            let loaded = await ConfigStore(fileURL: file, debounce: neverWithinATest).load()
            #expect(loaded.listening.source == .microphone)
            #expect(loaded.rules.isEmpty)
            let found = try backups(in: directory)
            #expect(found.count == 1, "\(json)")
            let backup = try #require(found.first)
            #expect(try Data(contentsOf: backup) == original)
            #expect(try Data(contentsOf: file) == original)  // a copy: loading does not touch config.json
        }
    }

    @Test(arguments: [#"{"name":"broken"}"#, #"{"terms":["y"]}"#, "42", "null", "[]", #""rule""#, "{}"])
    func droppedRuleElementIsBackedUp(broken: String) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data(#"{"rules":[{"name":"keep","terms":["k"]},\#(broken)]}"#.utf8)
            try original.write(to: file)

            // The rule that can be read is used, but the next save would drop the other one: the file is kept first.
            let loaded = await ConfigStore(fileURL: file, debounce: neverWithinATest).load()
            #expect(loaded.rules.map(\.name) == ["keep"])
            let found = try backups(in: directory)
            #expect(found.count == 1, "\(broken)")
            let backup = try #require(found.first)
            #expect(try Data(contentsOf: backup) == original)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aFileWhoseEveryRuleIsReadableIsNotBackedUpAndKeepsItsOrder() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try Data(#"{"rules":[{"name":"b","terms":["b"]},{"name":"a","terms":["a"]}]}"#.utf8).write(to: file)
            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded.rules.map(\.name) == ["b", "a"])
            #expect(try backups(in: directory).isEmpty)
        }
    }

    @Test func newerSchemaIsBackedUp() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data(#"{"schemaVersion":2,"rules":[{"name":"keep","terms":["k"]}]}"#.utf8)
            try original.write(to: file)

            // The rule would decode fine, but a newer app wrote this file: it is set aside, not half-read.
            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded == AppConfiguration())

            let found = try backups(in: directory)
            #expect(found.count == 1)
            let backup = try #require(found.first)
            let text = String(decoding: try Data(contentsOf: backup), as: UTF8.self)
            #expect(text.contains(#""keep""#))
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    @Test(arguments: [2, 3, 99, Int.max])
    func anyHigherSchemaVersionIsBackedUp(version: Int) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try Data(#"{"schemaVersion":\#(version)}"#.utf8).write(to: file)
            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded == AppConfiguration())
            #expect(try backups(in: directory).count == 1)
        }
    }

    @Test func everyCorruptLoadKeepsItsOwnBackup() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let store = ConfigStore(fileURL: file, debounce: neverWithinATest)
            let payloads = ["{one", "{two", "{three"].map { Data($0.utf8) }
            for payload in payloads {
                try payload.write(to: file)
                let loaded = await store.load()
                #expect(loaded == AppConfiguration())
            }
            // Loads within the same second share a timestamp and get -1, -2; no copy replaces an earlier one.
            let kept = try backups(in: directory).map { try Data(contentsOf: $0) }
            #expect(kept.count == 3)
            #expect(Set(kept) == Set(payloads))
        }
    }

    @Test func backupNameUsesLocalTimeAndNeverCollides() async throws {
        try await inTemporaryDirectory { directory in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 5, second: 3)
            let date = try #require(calendar.date(from: components))

            let first = ConfigStore.backupURL(in: directory, date: date)
            #expect(first.lastPathComponent == "config.corrupt-20261011-090503.json")
            #expect(first.deletingLastPathComponent().path == directory.path)

            try Data("one".utf8).write(to: first)
            let second = ConfigStore.backupURL(in: directory, date: date)
            #expect(second.lastPathComponent == "config.corrupt-20261011-090503-1.json")

            try Data("two".utf8).write(to: second)
            let third = ConfigStore.backupURL(in: directory, date: date)
            #expect(third.lastPathComponent == "config.corrupt-20261011-090503-2.json")
        }
    }

    // MARK: After a backup

    // A backup leaves config.json as it was, or takes it away. Without a write after it, every launch would find the
    // same file again and keep one more backup of it. So `load()` follows a backup with a normal, debounced save of
    // the configuration it returns. The exception is a file from a newer version of the app: it is kept, but it stays
    // where it is, so that going back to that version finds it unharmed.

    @Test func backupIsFollowedByOneNormalizingSave() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("{not json".utf8)
            try original.write(to: file)

            let store = ConfigStore(fileURL: file, debounce: .seconds(60))
            let loaded = await store.load()
            #expect(loaded == AppConfiguration())
            #expect(try backups(in: directory).count == 1)
            #expect(try Data(contentsOf: file) == original)  // a save, so deferred: nothing is written yet

            await store.flush()
            #expect(try readConfiguration(at: file) == loaded)
            #expect(try backups(in: directory).count == 1)

            // The next launch finds a good file, and keeps nothing more.
            let relaunched = await ConfigStore(fileURL: file).load()
            #expect(relaunched == loaded)
            #expect(try backups(in: directory).count == 1)

            // That was the one write: the save was used up, and flushing again does not repeat it.
            try FileManager.default.removeItem(at: file)
            await store.flush()
            #expect(!exists(file))
        }
    }

    @Test(arguments: [
        #"{"rules":[{"name":"keep","terms":["k"]},{"name":"broken"}]}"#,  // a rule that cannot be read
        #"{"rules":"oops","listening":{"source":"microphone"}}"#,  // rules that are not a list
    ])
    func aFileThatLostRulesIsFollowedByANormalizingSave(json: String) async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try Data(json.utf8).write(to: file)

            let store = ConfigStore(fileURL: file, debounce: .seconds(60))
            let loaded = await store.load()
            await store.flush()
            // What was read is what is written, so the next launch reads a file that has nothing left out.
            #expect(try readConfiguration(at: file) == loaded, "\(json)")

            let relaunched = await ConfigStore(fileURL: file).load()
            #expect(relaunched == loaded, "\(json)")
            #expect(try backups(in: directory).count == 1, "\(json)")
        }
    }

    @Test(.enabled(if: getuid() != 0, "root can read any file"))
    func aFileThatWasMovedAsideIsFollowedByANormalizingSave() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try Data("{not json".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            // Some file systems ignore permission bits. Then there is nothing to test.
            guard !FileManager.default.isReadableFile(atPath: file.path) else { return }

            let store = ConfigStore(fileURL: file, debounce: .seconds(60))
            let loaded = await store.load()
            #expect(!exists(file))  // moved, not copied
            #expect(try backups(in: directory).count == 1)

            await store.flush()
            #expect(try readConfiguration(at: file) == loaded)
            let relaunched = await ConfigStore(fileURL: file).load()
            #expect(relaunched == loaded)
            #expect(try backups(in: directory).count == 1)
        }
    }

    @Test func newerSchemaIsNotOverwrittenByLoad() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data(#"{"schemaVersion":2,"rules":[{"name":"keep","terms":["k"]}]}"#.utf8)
            try original.write(to: file)

            // A short debounce, so that a save scheduled by load() would long since have been written.
            let store = ConfigStore(fileURL: file, debounce: .milliseconds(10))
            let loaded = await store.load()
            #expect(loaded == AppConfiguration())
            try await Task.sleep(for: .milliseconds(100))
            await store.flush()

            // The newer version's file stays where it is, byte for byte. The copy is still made.
            #expect(try Data(contentsOf: file) == original)
            let found = try backups(in: directory)
            #expect(found.count == 1)
            let backup = try #require(found.first)
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    @Test func theNormalizingSaveIsDebouncedLikeAnyOther() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let original = Data("{not json".utf8)
            try original.write(to: file)

            // Long enough that a loaded machine cannot stall this test past it between load() and the check below.
            let debounce = Duration.seconds(1)
            let store = ConfigStore(fileURL: file, debounce: debounce)
            let loaded = await store.load()
            #expect(try Data(contentsOf: file) == original)

            // Nobody flushes: the timer writes it, once.
            let written = await waitUntil { (try? readConfiguration(at: file)) == loaded }
            #expect(written)
            try FileManager.default.removeItem(at: file)
            // A second write would come one debounce after the first, so look for it for longer than that.
            try await Task.sleep(for: debounce * 1.5)
            #expect(!exists(file))
        }
    }

    @Test func aFileThatNeededNoBackupIsNotWrittenBack() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")

            // No file: loading and flushing still create nothing.
            let first = ConfigStore(fileURL: file, debounce: .milliseconds(10))
            _ = await first.load()
            await first.flush()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

            // A good file is left as it is, byte for byte.
            let original = Data(#"{"rules":[{"name":"keep","terms":["k"]}]}"#.utf8)
            try original.write(to: file)
            let fileNumberBefore = try fileNumber(of: file)
            let second = ConfigStore(fileURL: file, debounce: .milliseconds(10))
            _ = await second.load()
            await second.flush()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try Data(contentsOf: file) == original)
            #expect(try fileNumber(of: file) == fileNumberBefore)
            #expect(try backups(in: directory).isEmpty)
        }
    }

    @Test func aSaveMadeBeforeLoadIsNotReplacedByTheNormalizingSave() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            try Data("{not json".utf8).write(to: file)
            let newer = makeConfiguration(ruleNamed: "newer")

            // load() is meant to run before the first save. If it does not, the newer value is still the one written.
            let store = ConfigStore(fileURL: file, debounce: .seconds(60))
            await store.save(newer)
            let loaded = await store.load()
            #expect(loaded == AppConfiguration())
            await store.flush()
            #expect(try readConfiguration(at: file) == newer)
        }
    }

    // MARK: Saving

    @Test func saveFlushLoad() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            var config = AppConfiguration()
            config.hasCompletedOnboarding = true
            config.rules = [
                Rule(
                    name: "x", terms: ["x", "ex"], sensitivity: .loose,
                    channels: [.sound, .ntfy], cooldownSeconds: 30
                ),
            ]
            config.channels.ntfy.topic = "team-a"
            config.globalCooldownSeconds = 7

            let store = ConfigStore(fileURL: file)
            await store.save(config)
            await store.flush()

            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded == config)
            let found = try backups(in: directory)
            #expect(found.isEmpty)  // a healthy round trip never sets anything aside
        }
    }

    @Test func debounceCoalesces() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let a = makeConfiguration(ruleNamed: "A")
            let b = makeConfiguration(ruleNamed: "B")
            #expect(a != b)

            let store = ConfigStore(fileURL: file, debounce: .milliseconds(300))
            await store.save(a)
            try await Task.sleep(for: .milliseconds(50))
            await store.save(b)
            await store.flush()

            let loaded = await ConfigStore(fileURL: file).load()
            #expect(loaded == b)
        }
    }

    @Test func savesWaitForTheDebounceOrAFlush() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let config = makeConfiguration(ruleNamed: "x")

            let store = ConfigStore(fileURL: file, debounce: .seconds(60))
            await store.save(config)
            #expect(!exists(file))  // deferred: nothing is on disk when save returns

            await store.flush()
            let onDisk = try readConfiguration(at: file)
            #expect(onDisk == config)
        }
    }

    @Test func timerWritesTheLatestValueOnceWithoutFlush() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let first = makeConfiguration(ruleNamed: "first")
            let last = makeConfiguration(ruleNamed: "last")

            let store = ConfigStore(fileURL: file, debounce: .milliseconds(400))
            await store.save(first)
            await store.save(last)

            // Nobody flushes: the timer started by the first save writes the file by itself, with the latest value.
            // Polled for that value, not for the file: on a busy machine the test may be slow to make its second
            // save, and the first timer may then write `first` on the way.
            let written = await waitUntil { (try? readConfiguration(at: file)) == last }
            #expect(written)

            // The burst produced a single write: once the file is removed, nothing brings it back.
            try FileManager.default.removeItem(at: file)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!exists(file))

            // And the timer slot was released, so a later save is written too.
            let later = makeConfiguration(ruleNamed: "later")
            await store.save(later)
            let writtenAgain = await waitUntil { (try? readConfiguration(at: file)) == later }
            #expect(writtenAgain)
        }
    }

    @Test func afterFlushNothingIsWrittenAgainAndLaterSavesStillWork() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let store = ConfigStore(fileURL: file, debounce: .milliseconds(200))
            await store.save(makeConfiguration(ruleNamed: "first"))
            await store.flush()
            #expect(exists(file))

            // The timer that was waiting when flush() ran must not write a second time ...
            try FileManager.default.removeItem(at: file)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!exists(file))

            // ... and flush() leaves the store able to schedule the next write.
            let second = makeConfiguration(ruleNamed: "second")
            await store.save(second)
            let written = await waitUntil { exists(file) }
            #expect(written)
            #expect(try readConfiguration(at: file) == second)
        }
    }

    @Test func flushCancelsTheTimerSoNothingKeepsTheStoreAlive() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            weak var weakStore: ConfigStore?
            do {
                let store = ConfigStore(fileURL: file, debounce: .seconds(3600))
                weakStore = store
                await store.save(makeConfiguration(ruleNamed: "x"))
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
            let file = directory.appendingPathComponent("config.json")
            let config = makeConfiguration(ruleNamed: "x")
            do {
                let store = ConfigStore(fileURL: file, debounce: .milliseconds(100))
                await store.save(config)
            }
            // Nobody holds the store any more, but its timer does until the write is done.
            let written = await waitUntil { exists(file) }
            #expect(written)
            let onDisk = try readConfiguration(at: file)
            #expect(onDisk == config)
        }
    }

    @Test func loadNeverWritesAndIgnoresUnflushedSaves() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let config = makeConfiguration(ruleNamed: "x")
            let store = ConfigStore(fileURL: file, debounce: .seconds(60))

            await store.save(config)
            let beforeFlush = await store.load()
            #expect(beforeFlush == AppConfiguration())  // load() is the file on disk, and that has nothing yet
            #expect(!exists(file))  // and asking for it does not push the pending value out

            await store.flush()
            let afterFlush = await store.load()
            #expect(afterFlush == config)
        }
    }

    @Test func flushWithNothingPendingWritesNothing() async throws {
        try await inTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("NameAlert", isDirectory: true)
            let file = folder.appendingPathComponent("config.json")
            let store = ConfigStore(fileURL: file)

            await store.flush()
            #expect(!exists(folder))  // not even the folder

            await store.save(makeConfiguration(ruleNamed: "x"))
            await store.flush()
            #expect(exists(file))

            // Already written, so a second flush has nothing to do.
            try FileManager.default.removeItem(at: file)
            await store.flush()
            #expect(!exists(file))
        }
    }

    @Test func writeCreatesTheFolderAndUsesPrettySortedJSON() async throws {
        try await inTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("Library/NameAlert", isDirectory: true)
            let file = folder.appendingPathComponent("config.json")
            #expect(!exists(folder))

            var config = makeConfiguration(ruleNamed: "x")
            config.channels.webhook.url = "https://example.com/hook"
            let store = ConfigStore(fileURL: file)
            await store.save(config)
            await store.flush()

            #expect(try readConfiguration(at: file) == config)
            // An atomic write leaves no temporary file behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["config.json"])

            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(text.hasPrefix("{\n  \""))  // pretty printed
            let keys = [
                "channels", "general", "globalCooldownSeconds", "hasCompletedOnboarding", "history",
                "listening", "rules", "schemaVersion", "speech",
            ]
            let positions = keys.map { text.range(of: "\n  \"\($0)\" : ")?.lowerBound }
            #expect(!positions.contains { $0 == nil }, "every top-level key is written")
            let offsets = positions.compactMap { $0 }.map { text.distance(from: text.startIndex, to: $0) }
            #expect(offsets == offsets.sorted(), "top-level keys are sorted")
        }
    }

    @Test func rewriteReplacesTheFileInsteadOfEditingItInPlace() async throws {
        try await inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("config.json")
            let store = ConfigStore(fileURL: file)

            await store.save(makeConfiguration(ruleNamed: "first"))
            await store.flush()
            let firstFile = try fileNumber(of: file)

            let second = makeConfiguration(ruleNamed: "second")
            await store.save(second)
            await store.flush()

            // An atomic write goes to a temporary file that is then renamed over the old one, so a crash or a full
            // disk halfway through leaves the previous config intact. The file number changing is how that shows.
            let secondFile = try fileNumber(of: file)
            #expect(secondFile != firstFile)
            #expect(try readConfiguration(at: file) == second)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
        }
    }

    @Test func failedWriteIsSurvivedAndRetried() async throws {
        try await inTemporaryDirectory { directory in
            // A plain file where the config folder should be: the folder cannot be created.
            let blocker = directory.appendingPathComponent("blocker")
            let blockerContents = Data("not a folder".utf8)
            try blockerContents.write(to: blocker)
            let file = blocker.appendingPathComponent("config.json")
            let config = makeConfiguration(ruleNamed: "x")

            let store = ConfigStore(fileURL: file, debounce: .milliseconds(10))
            await store.save(config)
            await store.flush()  // fails and logs; it must neither crash nor touch the file in the way
            #expect(try Data(contentsOf: blocker) == blockerContents)

            // The value was kept, so the next flush writes it once the path is usable.
            try FileManager.default.removeItem(at: blocker)
            await store.flush()
            #expect(try readConfiguration(at: file) == config)
        }
    }
}
