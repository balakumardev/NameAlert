import CryptoKit
import Foundation
import NameAlertCore
import Testing
import os

@testable import NameAlertSpeech

// MARK: - Helpers

/// The SHA-256 of "hello world".
private let helloWorldSHA256 = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
private let helloWorld = Data("hello world".utf8)

/// A body big enough for the network to hand over part of it while the connection is still open.
private let bigBody = patternedData(count: 200_000)
private let bigSHA256 = sha256Hex(bigBody)
/// The first part of it that a test lets through before it cuts the connection.
private let bigBodyStart = Data(bigBody.prefix(100_000))

/// A server that has `bigBody` and honors `Range`. A request without a range gets `first`, whatever it is.
private func resumableServer(first: StubServer.Reply) -> @Sendable (URLRequest) -> StubServer.Reply {
    { request in
        if let start = StubServer.rangeStart(of: request) { return StubServer.partialReply(of: bigBody, from: start) }
        return first
    }
}

/// Collects what a download reports as its progress.
private final class ProgressLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[Double]>(initialState: [])

    func record(_ fraction: Double) { storage.withLock { $0.append(fraction) } }
    var values: [Double] { storage.withLock { $0 } }
}

private func fileSize(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber
    else { return nil }
    return size.int64Value
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// `count` bytes that do not repeat for a while, so a chunk lost or written twice shows in the checksum.
private func patternedData(count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { bytes in
        for index in 0..<count { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8)) }
    }
    return data
}

/// True once `condition` holds. Gives up after `timeout`, so a test that goes wrong fails instead of hanging.
private func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A `ModelManager` that downloads from a stub server into a fresh temporary folder, which is removed afterwards.
/// Every model is described as `bytes` long with `sha256`, found at the stub's URL. The folder it uses does not exist
/// yet, like on a first run.
private final class Fixture: Sendable {
    let root: URL
    let directory: URL
    let server: StubServer
    let manager: ModelManager

    init(
        bytes: Int64 = Int64(helloWorld.count), sha256: String = helloWorldSHA256,
        availableSpace: @escaping @Sendable (URL) -> Int64? = { _ in .max },
        reply: @escaping @Sendable (URLRequest) -> StubServer.Reply
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("Models", isDirectory: true)
        let server = StubServer(reply: reply)
        self.root = root
        self.directory = directory
        self.server = server
        manager = ModelManager(
            directory: directory, session: server.session,
            descriptor: {
                ModelDescriptor(
                    model: $0, fileName: "\($0.rawValue).bin", bytes: bytes, sha256: sha256, url: server.url)
            },
            availableSpace: availableSpace)
    }

    deinit {
        server.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Where `.lightEnglish` ends up, and where it is downloaded to first.
    var finalURL: URL { directory.appendingPathComponent("\(WhisperModel.lightEnglish.rawValue).bin") }
    var partialURL: URL { finalURL.appendingPathExtension("partial") }

    func writeFinal(_ text: String) throws { try write(text, to: finalURL) }
    func writePartial(_ text: String) throws { try write(text, to: partialURL) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func contents(of url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func download(_ progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await manager.download(.lightEnglish, progress: progress)
    }
}

/// What a download reports: whole percents that only go up and never repeat, and 1.0 once, at the end.
private func isWellFormed(_ progress: [Double]) -> Bool {
    guard let last = progress.last, last == 1.0 else { return false }
    let steps = progress.dropLast()
    return zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 }
        && steps.allSatisfy { $0 >= 0 && $0 < 1 && abs($0 * 100 - ($0 * 100).rounded()) < 1e-9 }
}

// MARK: - Tests

// The time limit stops a test that waits on a held stub server from hanging the whole run.
@Suite("ModelManager", .timeLimit(.minutes(1)))
struct ModelManagerTests {
    // MARK: Catalog

    private struct SpecRow: Sendable {
        let model: WhisperModel
        let fileName: String
        let bytes: Int64
        let sha256: String
    }

    /// The table of spec section 8.6, typed out again.
    private static let specRows = [
        SpecRow(
            model: .lightEnglish, fileName: "ggml-tiny.en-q5_1.bin", bytes: 32_166_155,
            sha256: "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"),
        SpecRow(
            model: .lightMultilingual, fileName: "ggml-tiny-q5_1.bin", bytes: 32_152_673,
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"),
        SpecRow(
            model: .balancedEnglish, fileName: "ggml-base.en-q5_1.bin", bytes: 59_721_011,
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"),
        SpecRow(
            model: .balancedMultilingual, fileName: "ggml-base-q5_1.bin", bytes: 59_707_625,
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"),
        SpecRow(
            model: .vad, fileName: "ggml-silero-v5.1.2.bin", bytes: 885_098,
            sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"),
    ]

    @Test func catalogMatchesSpec() {
        let whisperFolder =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"
        for row in Self.specRows {
            let descriptor = ModelCatalog.descriptor(row.model)
            #expect(descriptor.model == row.model)
            #expect(descriptor.fileName == row.fileName, "\(row.model)")
            #expect(descriptor.bytes == row.bytes, "\(row.model)")
            #expect(descriptor.sha256 == row.sha256, "\(row.model)")
            if row.model != .vad {
                #expect(descriptor.url.absoluteString == whisperFolder + row.fileName, "\(row.model)")
            }
        }
        #expect(Self.specRows.map(\.model) == WhisperModel.allCases, "every model has a row")

        let balancedEnglish = ModelCatalog.descriptor(.balancedEnglish)
        #expect(balancedEnglish.fileName == "ggml-base.en-q5_1.bin")
        #expect(balancedEnglish.bytes == 59_721_011)
        #expect(balancedEnglish.sha256.hasPrefix("4baf70dd") && balancedEnglish.sha256.hasSuffix("dd2f"))

        let vad = ModelCatalog.descriptor(.vad)
        #expect(vad.url.host == "huggingface.co")
        #expect(vad.url.path.contains("9ffd54a1"))
        #expect(
            vad.url.absoluteString
                == "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin"
        )

        #expect(ModelCatalog.ramEstimateMB(.light) == 150)
        #expect(ModelCatalog.ramEstimateMB(.balanced) == 250)
    }

    struct LocaleCase: Sendable, CustomTestStringConvertible {
        let size: LocalModelSize
        let locale: String
        let expected: WhisperModel

        var testDescription: String { "\(size) \(locale)" }
    }

    static let localeCases = [
        LocaleCase(size: .light, locale: "en-US", expected: .lightEnglish),
        LocaleCase(size: .balanced, locale: "en-IN", expected: .balancedEnglish),
        LocaleCase(size: .light, locale: "de-DE", expected: .lightMultilingual),
        // The language is what comes before the first "-", "_" or "@".
        LocaleCase(size: .light, locale: "en", expected: .lightEnglish),
        LocaleCase(size: .balanced, locale: "en_GB", expected: .balancedEnglish),
        LocaleCase(size: .light, locale: "en_US@rg=inzzzz", expected: .lightEnglish),
        LocaleCase(size: .balanced, locale: "EN-us", expected: .balancedEnglish),
        LocaleCase(size: .balanced, locale: "ta-IN", expected: .balancedMultilingual),
        LocaleCase(size: .light, locale: "zh-Hans-CN", expected: .lightMultilingual),
        LocaleCase(size: .light, locale: "fr@calendar=gregorian", expected: .lightMultilingual),
        LocaleCase(size: .balanced, locale: "", expected: .balancedMultilingual),
    ]

    @Test(arguments: ModelManagerTests.localeCases)
    func modelSelection(_ row: LocaleCase) {
        #expect(ModelCatalog.model(size: row.size, localeIdentifier: row.locale) == row.expected)
    }

    // MARK: Downloading

    @Test func downloadsAndVerifies() async throws {
        let f = Fixture { _ in .ok("hello world") }
        let log = ProgressLog()

        try await f.download { log.record($0) }

        #expect(await f.manager.isInstalled(.lightEnglish))
        let installedFile = await f.manager.fileURL(for: .lightEnglish)
        #expect(installedFile == f.finalURL)
        #expect(try Data(contentsOf: installedFile) == helloWorld)
        #expect(log.values.last == 1.0)
        #expect(isWellFormed(log.values), "\(log.values)")
        #expect(!exists(f.partialURL), "the partial file is gone once it is the model")
        #expect(f.server.rangeHeaders == [nil], "a fresh download asks for the whole file")
    }

    @Test func checksumMismatchDeletesPartial() async throws {
        let f = Fixture { _ in .ok("hello WORLD") }
        let log = ProgressLog()

        await #expect(throws: ModelError.checksumMismatch) { try await f.download { log.record($0) } }

        #expect(await f.manager.isInstalled(.lightEnglish) == false)
        #expect(!exists(f.partialURL))
        #expect(!exists(f.finalURL))
        #expect(!log.values.contains(1.0), "a download that failed never says it is done")
    }

    @Test func resumesWithRange() async throws {
        let f = Fixture(reply: StubServer.serving(helloWorld))
        try f.writePartial("hello")
        let log = ProgressLog()

        try await f.download { log.record($0) }

        #expect(f.server.rangeHeaders == ["bytes=5-"])
        #expect(await f.manager.isInstalled(.lightEnglish))
        #expect(f.contents(of: f.finalURL) == "hello world")
        #expect(!exists(f.partialURL))
        #expect(log.values.first == 0.45, "the first report is where the download picked up: 5 of 11 bytes")
        #expect(isWellFormed(log.values), "\(log.values)")
    }

    @Test func serverIgnoresRange() async throws {
        let f = Fixture(reply: StubServer.serving(helloWorld, honoringRange: false))
        try f.writePartial("hello")

        try await f.download()

        #expect(f.server.rangeHeaders == ["bytes=5-"], "it was asked")
        #expect(await f.manager.isInstalled(.lightEnglish))
        #expect(f.contents(of: f.finalURL) == "hello world", "the 200 answer started the file over")
    }

    @Test func insufficientSpace() async throws {
        let f = Fixture(availableSpace: { _ in 10 }) { _ in .ok("hello world") }

        await #expect(throws: ModelError.insufficientSpace(required: 22, available: 10)) { try await f.download() }

        #expect(f.server.requests.isEmpty, "nothing is asked of the server when there is no room")
        #expect(await f.manager.isInstalled(.lightEnglish) == false)
    }

    @Test func spaceIsNeededOnlyForWhatIsStillMissing() async throws {
        // All 11 bytes are in the partial file already: nothing is downloaded, so no room is needed.
        let whole = Fixture(availableSpace: { _ in 0 }) { _ in .ok("never asked") }
        try whole.writePartial("hello world")
        try await whole.download()
        #expect(await whole.manager.isInstalled(.lightEnglish))
        #expect(whole.server.requests.isEmpty)

        // 5 of the 11 bytes are there: 2 x 11 - 5 = 17 bytes of room are needed.
        let short = Fixture(availableSpace: { _ in 16 }, reply: StubServer.serving(helloWorld))
        try short.writePartial("hello")
        await #expect(throws: ModelError.insufficientSpace(required: 17, available: 16)) { try await short.download() }
        #expect(short.server.requests.isEmpty)
        let enough = Fixture(availableSpace: { _ in 17 }, reply: StubServer.serving(helloWorld))
        try enough.writePartial("hello")
        try await enough.download()
        #expect(await enough.manager.isInstalled(.lightEnglish))
        #expect(enough.server.rangeHeaders == ["bytes=5-"])
    }

    @Test func unknownFreeSpaceDoesNotStopTheDownload() async throws {
        let f = Fixture(availableSpace: { _ in nil }) { _ in .ok("hello world") }
        try await f.download()
        #expect(await f.manager.isInstalled(.lightEnglish))
    }

    @Test func httpError() async throws {
        let f = Fixture { _ in StubServer.Reply(status: 404) }

        await #expect(throws: ModelError.httpStatus(404)) { try await f.download() }

        #expect(await f.manager.isInstalled(.lightEnglish) == false)
        #expect(!exists(f.partialURL))
    }

    @Test func serverErrorKeepsThePartialForALaterTry() async throws {
        let f = Fixture { _ in StubServer.Reply(status: 503) }
        try f.writePartial("hello")

        await #expect(throws: ModelError.httpStatus(503)) { try await f.download() }

        #expect(f.contents(of: f.partialURL) == "hello")
    }

    @Test func rangeNotSatisfiableDropsThePartial() async throws {
        // The server has fewer bytes than the partial file, so the partial file is not the start of its file.
        let f = Fixture { _ in StubServer.Reply(status: 416) }
        try f.writePartial("hello")

        await #expect(throws: ModelError.httpStatus(416)) { try await f.download() }

        #expect(!exists(f.partialURL), "otherwise every later try would ask for the same impossible range")
    }

    @Test func wrongSizeIsRejectedAndTheCopyDeleted() async throws {
        let tooLong = Fixture { _ in .ok("hello world!!!") }
        await #expect(throws: ModelError.sizeMismatch(expected: 11, actual: 14)) { try await tooLong.download() }
        #expect(!exists(tooLong.partialURL))
        #expect(!exists(tooLong.finalURL))

        let tooShort = Fixture { _ in .ok("hello") }
        await #expect(throws: ModelError.sizeMismatch(expected: 11, actual: 5)) { try await tooShort.download() }
        #expect(!exists(tooShort.partialURL))
        #expect(await tooShort.manager.isInstalled(.lightEnglish) == false)
    }

    // MARK: What is on disk

    @Test func installedNeedsTheExactSize() async throws {
        let f = Fixture { _ in .ok("") }
        #expect(await f.manager.isInstalled(.lightEnglish) == false, "no folder yet")

        try f.writeFinal("hello worl")
        #expect(await f.manager.isInstalled(.lightEnglish) == false, "one byte short")
        try f.writeFinal("hello world!")
        #expect(await f.manager.isInstalled(.lightEnglish) == false, "one byte long")
        try f.writeFinal("hello world")
        #expect(await f.manager.isInstalled(.lightEnglish))

        try FileManager.default.removeItem(at: f.finalURL)
        try f.writePartial("hello world")
        #expect(await f.manager.isInstalled(.lightEnglish) == false, "a partial file is never the model")
    }

    @Test func alreadyInstalledMakesNoRequest() async throws {
        let f = Fixture { _ in .ok("never asked") }
        try f.writeFinal("hello world")
        let log = ProgressLog()

        try await f.download { log.record($0) }

        #expect(f.server.requests.isEmpty)
        #expect(log.values == [1.0])
    }

    @Test func wholePartialIsCheckedWithoutAskingTheServer() async throws {
        // The app was closed after the last byte and before the check. Asking for `bytes=11-` would get a 416.
        let f = Fixture { _ in .ok("never asked") }
        try f.writePartial("hello world")

        try await f.download()

        #expect(f.server.requests.isEmpty)
        #expect(await f.manager.isInstalled(.lightEnglish))
        #expect(f.contents(of: f.finalURL) == "hello world")
        #expect(!exists(f.partialURL))
    }

    @Test func wholeButCorruptPartialIsDeleted() async throws {
        let f = Fixture { _ in .ok("never asked") }
        try f.writePartial("hello WORLD")

        await #expect(throws: ModelError.checksumMismatch) { try await f.download() }

        #expect(f.server.requests.isEmpty)
        #expect(!exists(f.partialURL))
        #expect(await f.manager.isInstalled(.lightEnglish) == false)
    }

    @Test func partialLongerThanTheModelStartsOver() async throws {
        let f = Fixture(reply: StubServer.serving(helloWorld))
        try f.writePartial("hello world, and then some")

        try await f.download()

        #expect(f.server.rangeHeaders == [nil], "no range can be asked for from a file that is too long")
        #expect(f.contents(of: f.finalURL) == "hello world")
    }

    @Test func staleFileOfTheWrongSizeIsReplaced() async throws {
        let f = Fixture(reply: StubServer.serving(helloWorld))
        try f.writeFinal("an older, longer model")

        try await f.download()

        #expect(f.contents(of: f.finalURL) == "hello world")
        #expect(await f.manager.isInstalled(.lightEnglish))
    }

    @Test func deleteRemoves() async throws {
        let f = Fixture(reply: StubServer.serving(helloWorld))
        try await f.download()
        #expect(await f.manager.isInstalled(.lightEnglish))

        try await f.manager.delete(.lightEnglish)

        #expect(await f.manager.isInstalled(.lightEnglish) == false)
        #expect(!exists(f.finalURL))
    }

    @Test func deleteRemovesTheFinalAndThePartialFile() async throws {
        let f = Fixture { _ in .ok("") }
        try f.writeFinal("hello world")
        try f.writePartial("hello")

        try await f.manager.delete(.lightEnglish)

        #expect(!exists(f.finalURL))
        #expect(!exists(f.partialURL))
    }

    @Test func deletingWhatIsNotThereIsFine() async throws {
        let f = Fixture { _ in .ok("") }
        try await f.manager.delete(.lightEnglish)
    }

    // MARK: Interrupted downloads

    @Test func cancelledDownloadKeepsThePartialAndResumes() async throws {
        // The first answer is never ended: the client gives up.
        let f = Fixture(
            bytes: Int64(bigBody.count), sha256: bigSHA256,
            reply: resumableServer(first: StubServer.Reply(chunks: [bigBodyStart], hold: .beforeEnd)))
        let download = Task { try await f.download() }
        #expect(await eventually { (fileSize(f.partialURL) ?? 0) >= 65_536 })

        download.cancel()

        await #expect(throws: CancellationError.self) { try await download.value }
        let kept = try #require(fileSize(f.partialURL), "what arrived is kept")
        #expect(kept <= Int64(bigBodyStart.count))
        #expect(try Data(contentsOf: f.partialURL) == bigBody.prefix(Int(kept)), "and it is the start of the file")
        #expect(await f.manager.isInstalled(.lightEnglish) == false)

        try await f.download()

        #expect(f.server.rangeHeaders == [nil, "bytes=\(kept)-"], "the second try picks up where the first stopped")
        #expect(try Data(contentsOf: f.finalURL) == bigBody)
        #expect(!exists(f.partialURL))
    }

    @Test func droppedConnectionKeepsThePartialAndResumes() async throws {
        let dropped = StubServer.Reply(
            chunks: [bigBodyStart], error: URLError(.networkConnectionLost), hold: .beforeEnd)
        let f = Fixture(bytes: Int64(bigBody.count), sha256: bigSHA256, reply: resumableServer(first: dropped))
        let download = Task { try await f.download() }
        #expect(await eventually { (fileSize(f.partialURL) ?? 0) >= 65_536 })

        f.server.release()  // the network drops

        await #expect(throws: URLError.self) { try await download.value }
        let kept = try #require(fileSize(f.partialURL), "what arrived is kept")
        #expect(try Data(contentsOf: f.partialURL) == bigBody.prefix(Int(kept)))
        #expect(await f.manager.isInstalled(.lightEnglish) == false)

        try await f.download()

        #expect(f.server.rangeHeaders == [nil, "bytes=\(kept)-"])
        #expect(try Data(contentsOf: f.finalURL) == bigBody)
    }

    @Test func largeFileIsWrittenAndCheckedInFull() async throws {
        // Three 1 MB blocks to hash, arriving in 40 chunks: nothing may be lost or written twice between them.
        let body = patternedData(count: 2_500_000)
        let chunkSize = 62_500
        let f = Fixture(bytes: Int64(body.count), sha256: sha256Hex(body)) { _ in
            StubServer.Reply(
                chunks: stride(from: 0, to: body.count, by: chunkSize).map {
                    Data(body[$0..<min($0 + chunkSize, body.count)])
                })
        }
        let log = ProgressLog()

        try await f.download { log.record($0) }

        #expect(try Data(contentsOf: f.finalURL) == body)
        #expect(isWellFormed(log.values), "\(log.values)")
    }

    @Test func bodyThatNeverEndsIsCutOffOnceItIsTooLong() async throws {
        // The server keeps the connection open and never finishes. The download stops taking bytes once it has more
        // than the model.
        let f = Fixture(bytes: 1_000, sha256: bigSHA256) { _ in
            StubServer.Reply(chunks: [bigBodyStart], hold: .beforeEnd)
        }

        do {
            try await f.download()
            Issue.record("expected the download to fail")
        } catch let ModelError.sizeMismatch(expected, actual) {
            #expect(expected == 1_000)
            #expect(actual > 1_000)
        }
        #expect(!exists(f.partialURL))
        #expect(await f.manager.isInstalled(.lightEnglish) == false)
    }

    @Test func callCancelledBeforeItStartsDownloadsNothing() async throws {
        let f = Fixture { _ in .ok("hello world") }
        let call = Task {
            while !Task.isCancelled { await Task.yield() }
            try await f.download()
        }

        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(f.server.requests.isEmpty)
        #expect(await f.manager.waiterCount(of: .lightEnglish) == 0)
        #expect(await f.manager.isInstalled(.lightEnglish) == false)
    }

    // MARK: Concurrent calls

    @Test func concurrentCallsShareOneDownload() async throws {
        let f = Fixture { _ in StubServer.Reply(chunks: [helloWorld], hold: .beforeAnswer) }
        let firstLog = ProgressLog()
        let secondLog = ProgressLog()
        let first = Task { try await f.download { firstLog.record($0) } }
        let second = Task { try await f.download { secondLog.record($0) } }
        #expect(await eventually { await f.manager.waiterCount(of: .lightEnglish) == 2 })

        f.server.release()
        try await first.value
        try await second.value

        #expect(f.server.requests.count == 1, "the second call waited for the first instead of starting its own")
        #expect(await f.manager.isInstalled(.lightEnglish))
        #expect(f.contents(of: f.finalURL) == "hello world")
        #expect(firstLog.values.last == 1.0)
        #expect(secondLog.values.last == 1.0, "a call that joins a running download hears about it too")
        #expect(await f.manager.waiterCount(of: .lightEnglish) == 0)
    }

    @Test func concurrentCallsShareTheFailure() async throws {
        let f = Fixture { _ in StubServer.Reply(status: 500, hold: .beforeAnswer) }
        let first = Task { try await f.download() }
        let second = Task { try await f.download() }
        #expect(await eventually { await f.manager.waiterCount(of: .lightEnglish) == 2 })

        f.server.release()

        await #expect(throws: ModelError.httpStatus(500)) { try await first.value }
        await #expect(throws: ModelError.httpStatus(500)) { try await second.value }
        #expect(f.server.requests.count == 1)
    }

    @Test func cancellingOneCallerLeavesTheDownloadToTheOther() async throws {
        let f = Fixture { _ in StubServer.Reply(chunks: [helloWorld], hold: .beforeAnswer) }
        let firstLog = ProgressLog()
        let secondLog = ProgressLog()
        let first = Task { try await f.download { firstLog.record($0) } }
        let second = Task { try await f.download { secondLog.record($0) } }
        #expect(await eventually { await f.manager.waiterCount(of: .lightEnglish) == 2 })

        first.cancel()

        #expect(await eventually { await f.manager.waiterCount(of: .lightEnglish) == 1 })
        await #expect(throws: CancellationError.self) { try await first.value }
        f.server.release()
        try await second.value
        #expect(f.server.requests.count == 1, "the download went on for the call that still wanted it")
        #expect(await f.manager.isInstalled(.lightEnglish))
        #expect(f.contents(of: f.finalURL) == "hello world")
        #expect(secondLog.values.last == 1.0)
        #expect(firstLog.values.isEmpty, "a call that left hears nothing more")
    }

    @Test func callRightAfterACancelNeitherJoinsNorOverlapsTheStoppingDownload() async throws {
        // Whether the second call comes before or after the first download has been told to stop, it must end up with
        // the whole model: by sharing that download, or by waiting for it to close its file and starting from there.
        let f = Fixture(
            bytes: Int64(bigBody.count), sha256: bigSHA256,
            reply: resumableServer(first: StubServer.Reply(chunks: [bigBody], hold: .beforeEnd)))
        let first = Task { try await f.download() }
        #expect(await eventually { (fileSize(f.partialURL) ?? 0) >= 65_536 })

        first.cancel()
        let second = Task { try await f.download() }
        f.server.release()

        try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try Data(contentsOf: f.finalURL) == bigBody)
        #expect(!exists(f.partialURL))
        #expect(await f.manager.waiterCount(of: .lightEnglish) == 0)
    }

    @Test func deleteStopsADownloadInProgress() async throws {
        let f = Fixture(bytes: Int64(bigBody.count), sha256: bigSHA256) { _ in
            StubServer.Reply(chunks: [bigBodyStart], hold: .beforeEnd)
        }
        let download = Task { try await f.download() }
        #expect(await eventually { (fileSize(f.partialURL) ?? 0) >= 65_536 })

        try await f.manager.delete(.lightEnglish)

        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!exists(f.partialURL), "the download does not write the file again after the delete")
        #expect(!exists(f.finalURL))
        #expect(await f.manager.waiterCount(of: .lightEnglish) == 0)
    }

    // MARK: Progress

    @Test func throttleReportsEachWholePercentOnce() {
        var throttle = ProgressThrottle(expected: 10_000)
        var seen: [Double] = []
        for written in stride(from: Int64(0), through: 10_000, by: 7) {
            if let fraction = throttle.update(written: written) { seen.append(fraction) }
        }

        #expect(seen == (1...99).map { Double($0) / 100 })
        #expect(throttle.update(written: 10_000) == nil, "100 % is for complete() to say")
        #expect(throttle.complete() == 1.0)
        #expect(throttle.complete() == nil)
    }

    @Test func throttleStartsWhereTheDownloadPicksUp() {
        var throttle = ProgressThrottle(expected: 10_000)
        #expect(throttle.update(written: 4_321) == 0.43)
        #expect(throttle.update(written: 4_399) == nil)
        #expect(throttle.update(written: 4_400) == 0.44)
    }

    @Test func throttleNeedsAKnownSize() {
        var throttle = ProgressThrottle(expected: 0)
        #expect(throttle.update(written: 5) == nil)
    }

    // MARK: Free space

    @Test func defaultAvailableSpaceLooksAtTheVolume() throws {
        let temporary = FileManager.default.temporaryDirectory
        let space = try #require(ModelManager.defaultAvailableSpace(temporary))
        #expect(space > 0)
        // A folder that is not there yet is measured by the closest folder that is.
        let missing = temporary.appendingPathComponent("NameAlertTests-\(UUID().uuidString)/Models", isDirectory: true)
        #expect(ModelManager.defaultAvailableSpace(missing) != nil)
    }

    // MARK: Real server

    @Test(
        "Downloads the real VAD model, and finishes a cut-off copy of it",
        .enabled(if: ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1"))
    func liveVADDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertLive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The real catalog, the real session, the real server.
        let manager = ModelManager(directory: root.appendingPathComponent("Models", isDirectory: true))
        let log = ProgressLog()
        try await manager.download(.vad) { log.record($0) }

        let installedFile = await manager.fileURL(for: .vad)
        #expect(await manager.isInstalled(.vad))
        #expect(fileSize(installedFile) == 885_098)
        #expect(log.values.last == 1.0)
        #expect(!exists(installedFile.appendingPathExtension("partial")))

        // Keep the first 300 000 bytes as a partial file, and let a second manager finish the job. The server
        // answers a Range request with 206, so the download reports where it picked up (300 000 of 885 098).
        let whole = try Data(contentsOf: installedFile)
        let resumed = ModelManager(directory: root.appendingPathComponent("Resume", isDirectory: true))
        let resumedFile = await resumed.fileURL(for: .vad)
        try FileManager.default.createDirectory(
            at: resumedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try whole.prefix(300_000).write(to: resumedFile.appendingPathExtension("partial"))
        let resumeLog = ProgressLog()
        try await resumed.download(.vad) { resumeLog.record($0) }

        #expect(await resumed.isInstalled(.vad))
        #expect(try Data(contentsOf: resumedFile) == whole)
        #expect(resumeLog.values.first == 0.33)
    }
}
