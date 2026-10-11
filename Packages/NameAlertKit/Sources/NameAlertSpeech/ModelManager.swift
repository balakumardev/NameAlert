import CryptoKit
import Foundation
import NameAlertCore
import os

// MARK: - Errors and the protocol

/// Why a model could not be downloaded.
///
/// A download that is cancelled throws `CancellationError`. One that loses the network throws the `URLError`.
public enum ModelError: Error, Equatable {
    /// The disk has less room than a download needs. Both numbers are in bytes.
    case insufficientSpace(required: Int64, available: Int64)
    /// The file arrived whole, but it is not the file the catalog pins: its SHA-256 is different.
    case checksumMismatch
    /// The file has another size than the catalog says.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The server answered with an HTTP status that is not the file. The number is that status.
    case httpStatus(Int)
}

/// The model files, as the rest of the app sees them.
public protocol ModelProviding: Sendable {
    /// True when the model's file is on disk with the size it should have.
    func isInstalled(_ model: WhisperModel) async -> Bool

    /// Downloads the model, unless it is installed already. `progress` gets numbers from 0 to 1 while the file comes
    /// in, from any thread, at most one for each whole percent, and a last 1.0 once the file is checked and in
    /// place. All of it is called before this returns or throws, and none of it after. Cancelling the task that runs
    /// this keeps what has arrived, so the next call picks up from there.
    func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Removes the model's file and any half-downloaded copy of it.
    func delete(_ model: WhisperModel) async throws
}

// MARK: - ModelManager

/// Downloads the model files into one folder and keeps track of which of them can be used.
///
/// A model file is only ever in its final place when it is whole and checked. A download writes to
/// `<file>.partial` and, when everything has arrived, checks the size and the SHA-256 against the catalog (the hash
/// is read from disk in 1 MB blocks, so the file is never in memory). Only then is the partial file renamed to the
/// final name, in one step. If the check fails, the partial file is deleted and the download throws, so a corrupt
/// file is never kept and never taken for a model.
///
/// A download that stops early keeps its partial file. That covers a cancelled task, a lost network and a quit app.
/// The next call asks the server for the rest with a `Range` header and appends it (HTTP 206). A server that
/// answers 200 instead is sending the whole file, and the partial file starts over. A partial file that already has
/// all the bytes (the app quit before the check) goes straight to the check, and one that is longer than the model
/// can only be wrong, so it is deleted.
///
/// A download needs free space of twice the model's size, and fails with `insufficientSpace` before it asks the
/// server for anything when there is less. The folder is created the first time a download needs it.
///
/// Calls for the same model share one download. A second `download` while one is running waits for it, hears its
/// progress and gets its result. Cancelling one of several callers only takes that caller out; the download stops
/// when no caller is left. `delete` stops a running download of its model first, so the file cannot come back after it.
///
/// `isInstalled` is the quick check: the final file exists and has the right size. It does not read the file; the
/// checksum was verified before the file got its name.
///
/// Calls are shared per manager. Use one manager for a folder.
public actor ModelManager: ModelProviding {
    private let directory: URL
    private let session: URLSession
    private let descriptor: @Sendable (WhisperModel) -> ModelDescriptor
    private let availableSpace: @Sendable (URL) -> Int64?
    private let logger = Log.logger("models")

    /// The downloads that are running, one per model.
    private var flights: [WhisperModel: Flight] = [:]

    /// One running download, and the calls that wait for it.
    private final class Flight {
        /// The download itself. It ends by calling `finish`.
        let task: Task<Void, Never>
        let progress: ProgressFanOut
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

        init(task: Task<Void, Never>, progress: ProgressFanOut) {
            self.task = task
            self.progress = progress
        }
    }

    public init(
        directory: URL = AppPaths.modelsDirectory, session: URLSession = .shared,
        descriptor: @escaping @Sendable (WhisperModel) -> ModelDescriptor = ModelCatalog.descriptor,
        availableSpace: @escaping @Sendable (URL) -> Int64? = ModelManager.defaultAvailableSpace
    ) {
        self.directory = directory
        self.session = session
        self.descriptor = descriptor
        self.availableSpace = availableSpace
    }

    // MARK: Where things are

    /// Where the model's file is, or will be once it is installed.
    public func fileURL(for model: WhisperModel) -> URL {
        descriptor(model).finalURL(in: directory)
    }

    private func partialURL(for model: WhisperModel) -> URL {
        descriptor(model).partialURL(in: directory)
    }

    /// The room left on the volume that holds `url`, for things the user cares about (the system can free some
    /// space on demand, and this counts it). Nil when the volume does not say. A folder that does not exist yet is
    /// measured by the closest folder above it that does.
    public static func defaultAvailableSpace(_ url: URL) -> Int64? {
        var location = url
        while !FileManager.default.fileExists(atPath: location.path), location.pathComponents.count > 1 {
            location = location.deletingLastPathComponent()
        }
        let values = try? location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public func isInstalled(_ model: WhisperModel) -> Bool {
        Disk.regularFileSize(at: fileURL(for: model)) == descriptor(model).bytes
    }

    /// How many calls are waiting for the download of `model`. For tests.
    func waiterCount(of model: WhisperModel) -> Int {
        flights[model]?.waiters.count ?? 0
    }

    // MARK: Downloading

    public func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled(model) {
            progress(1)
            return
        }
        // A download that has been told to stop is still closing its file (its callers all left, or the model is being
        // deleted). Do not join it, and do not start another beside it: let it finish, then look at the disk again.
        while let flight = flights[model], flight.task.isCancelled {
            await flight.task.value
        }
        if isInstalled(model) {
            progress(1)
            return
        }

        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    join(model, as: id, continuation: continuation, progress: progress)
                }
            } onCancel: {
                Task { await self.leave(model, id: id) }
            }
        } catch is CancellationError {
            // If this call was the last one waiting, the download is still closing its file. Do not report back
            // before it has, so a call that follows finds the partial file whole and not in use.
            if let flight = flights[model], flight.task.isCancelled {
                await flight.task.value
            }
            throw CancellationError()
        }
    }

    public func delete(_ model: WhisperModel) async throws {
        // A running download would write the file again behind our back.
        while let flight = flights[model] {
            flight.task.cancel()
            await flight.task.value
        }
        // Try both files even if the first cannot be removed, then report the first problem.
        var firstError: (any Error)?
        for url in [fileURL(for: model), partialURL(for: model)] {
            do {
                try Disk.removeIfPresent(url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: Sharing a download between calls

    /// Adds a call to the download of `model`, which starts if none is running.
    private func join(
        _ model: WhisperModel, as id: UUID, continuation: CheckedContinuation<Void, any Error>,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        // Cancelled before it got here: its cancellation handler has run already and found nothing to take out.
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let flight = flights[model] {
            flight.progress.add(progress, for: id)
            flight.waiters[id] = continuation
        } else {
            let fanOut = ProgressFanOut()
            fanOut.add(progress, for: id)  // before the download starts, so it hears the first report
            let flight = Flight(task: startDownload(of: model, reportingTo: fanOut), progress: fanOut)
            flight.waiters[id] = continuation
            flights[model] = flight
        }
    }

    /// Takes a cancelled call out. The download stops when it was the last one waiting.
    private func leave(_ model: WhisperModel, id: UUID) {
        guard let flight = flights[model], let continuation = flight.waiters.removeValue(forKey: id) else { return }
        flight.progress.remove(id)
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
        }
    }

    /// The end of a download: hands its result to every call that still waits.
    private func finish(_ model: WhisperModel, with result: Result<Void, any Error>) {
        guard let flight = flights.removeValue(forKey: model) else { return }
        for continuation in flight.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func startDownload(of model: WhisperModel, reportingTo fanOut: ProgressFanOut) -> Task<Void, Never> {
        let job = DownloadJob(
            descriptor: descriptor(model), directory: directory, session: session, availableSpace: availableSpace,
            logger: logger, report: { fanOut.send($0) })
        // Detached, so the work (disk, hashing) never runs on this actor.
        return Task.detached { [self] in
            let result: Result<Void, any Error>
            do {
                try await job.run()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await finish(model, with: result)
        }
    }
}

// MARK: - Progress

/// Turns a growing byte count into progress reports, at most one for each whole percent.
///
/// It never says 100 %. That is `complete()`, which a download calls once the file is checked and in place, so a
/// download that fails its check never reported that it was done.
struct ProgressThrottle {
    private let expected: Int64
    private var lastPercent = 0
    private var isComplete = false

    init(expected: Int64) {
        self.expected = expected
    }

    /// The new fraction (0.01 to 0.99) when `written` bytes reach a whole percent that was not reported yet.
    mutating func update(written: Int64) -> Double? {
        guard expected > 0, written > 0 else { return nil }
        let percent = Int(min(99, written * 100 / expected))
        guard percent > lastPercent else { return nil }
        lastPercent = percent
        return Double(percent) / 100
    }

    /// 1.0 the first time, then nil.
    mutating func complete() -> Double? {
        guard !isComplete else { return nil }
        isComplete = true
        return 1
    }
}

/// Passes a download's progress on to every call that waits for it.
///
/// The calls happen one at a time, under a lock, and `remove` waits for one that is running. So once a call has been
/// removed it is never called again, and a call that is told the download is over has heard all of it.
private final class ProgressFanOut: Sendable {
    private let observers = OSAllocatedUnfairLock<[UUID: @Sendable (Double) -> Void]>(initialState: [:])

    func add(_ observer: @escaping @Sendable (Double) -> Void, for id: UUID) {
        observers.withLock { $0[id] = observer }
    }

    func remove(_ id: UUID) {
        observers.withLock { $0[id] = nil }
    }

    func send(_ fraction: Double) {
        observers.withLock { observers in
            for observer in observers.values {
                observer(fraction)
            }
        }
    }
}

// MARK: - The download

private extension ModelDescriptor {
    func finalURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func partialURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName + ".partial", isDirectory: false)
    }
}

/// What a download task reports, in the order it happens: the answer, then the bytes.
private enum DownloadEvent: Sendable {
    case head(HTTPURLResponse)
    case body(Data)
}

/// Hands what a data task receives to an async stream.
///
/// The bytes come in the chunks the network delivers them in. (Reading them one by one with
/// `URLSession.bytes(for:)` was measured at about 7 seconds a megabyte on the Mac this was written on, which would
/// make a 60 MB model a matter of minutes of CPU.)
private final class EventDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let response = response as? HTTPURLResponse {
            continuation.yield(.head(response))
            completionHandler(.allow)
        } else {
            continuation.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.body(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}

/// Cancels a task from wherever the stream ends. `URLSessionTask.cancel()` is safe to call from any thread.
private struct TaskCanceller: @unchecked Sendable {
    let task: URLSessionTask

    func cancel() {
        task.cancel()
    }
}

/// The partial file, open for writing.
private final class PartialFile {
    private let handle: FileHandle

    /// Opens the file, creating it if it is not there. Keeps its first `keptBytes` bytes, drops the rest, and
    /// leaves the write position at the end.
    init(at url: URL, keeping keptBytes: Int64) throws {
        if !FileManager.default.fileExists(atPath: url.path),
            !FileManager.default.createFile(atPath: url.path, contents: nil)
        {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: UInt64(keptBytes))
            try handle.seek(toOffset: UInt64(keptBytes))
        } catch {
            try? handle.close()
            throw error
        }
    }

    func append(_ data: Data) throws {
        try autoreleasepool { try handle.write(contentsOf: data) }
    }

    /// Makes sure every byte is on disk, then closes. Used when the download has ended without a problem.
    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }

    /// Closes after a failure or a cancel. What was written stays, as the start of the next try.
    func abandon() {
        try? handle.close()
    }
}

private enum Disk {
    /// The size of the file at `url`, or nil when there is nothing there or it is not a plain file.
    static func regularFileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}

/// One download of one model, from the first check to the last rename. It runs off the model manager's actor.
private struct DownloadJob: Sendable {
    let descriptor: ModelDescriptor
    let directory: URL
    let session: URLSession
    let availableSpace: @Sendable (URL) -> Int64?
    let logger: Logger
    /// Gets the progress, a number from 0 to 1.
    let report: @Sendable (Double) -> Void

    private var finalURL: URL { descriptor.finalURL(in: directory) }
    private var partialURL: URL { descriptor.partialURL(in: directory) }
    private static let hashBlockSize = 1_048_576

    func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let required = descriptor.bytes * 2
        if let available = availableSpace(directory), available < required {
            throw ModelError.insufficientSpace(required: required, available: available)
        }

        var throttle = ProgressThrottle(expected: descriptor.bytes)
        let have = try sizeOfUsablePartial()
        if have < descriptor.bytes {
            try await fetch(resumingAt: have, throttle: &throttle)
        }
        try verifyAndInstall(throttle: &throttle)
    }

    /// How many bytes of the model the partial file already holds. A partial file that cannot be the start of the
    /// model (it is longer than the model, or is not a plain file) is deleted, and counts as nothing.
    private func sizeOfUsablePartial() throws -> Int64 {
        if let size = Disk.regularFileSize(at: partialURL), size <= descriptor.bytes {
            return size
        }
        try Disk.removeIfPresent(partialURL)
        return 0
    }

    // MARK: Fetching

    /// Gets the rest of the file from the server, from byte `offset` on, and appends it to the partial file.
    private func fetch(resumingAt offset: Int64, throttle: inout ProgressThrottle) async throws {
        var request = URLRequest(url: descriptor.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A byte range counts the bytes as they are sent. A compressed answer would make the two disagree.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            logger.info("Resuming \(descriptor.fileName, privacy: .public) at byte \(offset) of \(descriptor.bytes)")
        } else {
            logger.info("Downloading \(descriptor.fileName, privacy: .public)")
        }

        let (events, continuation) = AsyncThrowingStream<DownloadEvent, any Error>.makeStream()
        let delegate = EventDelegate(continuation)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        // The stream ends when the task does, and the task ends when the stream does (we stop reading, or are
        // cancelled). The delegate is kept for as long as the stream lives.
        let canceller = TaskCanceller(task: task)
        continuation.onTermination = { [delegate] _ in
            canceller.cancel()
            _ = delegate
        }
        task.resume()
        defer { task.cancel() }

        var file: PartialFile?
        var written: Int64 = 0
        do {
            receiving: for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .head(let response):
                    switch response.statusCode {
                    case 206:
                        written = offset
                    case 200:
                        written = 0
                    case 416 where offset > 0:
                        // The server has fewer bytes than the partial file, so the partial file is not the start of
                        // what it serves. Another try asking for the same range would get the same answer.
                        discardPartial(because: "the server could not serve bytes from \(offset)")
                        throw ModelError.httpStatus(416)
                    case let status:
                        throw ModelError.httpStatus(status)
                    }
                    file = try PartialFile(at: partialURL, keeping: written)
                    if let fraction = throttle.update(written: written) { report(fraction) }
                case .body(let data):
                    guard let file else { continue receiving }
                    try file.append(data)
                    written += Int64(data.count)
                    if let fraction = throttle.update(written: written) { report(fraction) }
                    if written > descriptor.bytes {
                        // More than the whole file: this is not the file. Stop taking it; the size check says so.
                        break receiving
                    }
                }
            }
        } catch {
            file?.abandon()
            if Task.isCancelled, error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }

        // Cancelling ends the stream early and quietly. That is not a finished download.
        if Task.isCancelled {
            file?.abandon()
            throw CancellationError()
        }
        guard let file else { throw URLError(.badServerResponse) }  // the stream ended without an answer
        try file.finish()
    }

    // MARK: Checking

    /// Checks the partial file against the catalog and, if it is the model, gives it the final name.
    private func verifyAndInstall(throttle: inout ProgressThrottle) throws {
        let actual = Disk.regularFileSize(at: partialURL) ?? 0
        guard actual == descriptor.bytes else {
            discardPartial(because: "it has \(actual) bytes, not \(descriptor.bytes)")
            throw ModelError.sizeMismatch(expected: descriptor.bytes, actual: actual)
        }
        guard try sha256Hex(ofFileAt: partialURL) == descriptor.sha256.lowercased() else {
            discardPartial(because: "its SHA-256 is not the one the catalog pins")
            throw ModelError.checksumMismatch
        }

        // Anything at the final name is not this model (it would have been installed), so it makes room.
        try Disk.removeIfPresent(finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        logger.info("Installed \(descriptor.fileName, privacy: .public)")
        if let fraction = throttle.complete() { report(fraction) }
    }

    private func discardPartial(because reason: String) {
        logger.error("Deleting the partial \(descriptor.fileName, privacy: .public): \(reason, privacy: .public)")
        do {
            try Disk.removeIfPresent(partialURL)
        } catch {
            logger.error("Could not delete it: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The SHA-256 of a file as lowercase hex, read in 1 MB blocks. Stops early when the task is cancelled.
    private func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let block = try autoreleasepool { try handle.read(upToCount: Self.hashBlockSize) }
            guard let block, !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
