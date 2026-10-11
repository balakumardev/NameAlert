import NameAlertAudio
import NameAlertCore
import Testing

// MARK: - Helpers

/// Holds a fake's `start()` until the test opens it, so a test can act while a start is in progress.
private actor StartLatch {
    private var isOpen = false
    private var hasArrived = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the fake's `start()`; returns once the latch is open.
    func park() async {
        hasArrived = true
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Returns once a `start()` is parked here.
    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in parked {
            continuation.resume()
        }
        parked.removeAll()
    }
}

/// A capture source that hands out scripted chunks, so `MixedSource` can be tested without audio hardware.
///
/// Every `start()` returns a fresh stream that already holds the script. The stream then stays open until `stop()`,
/// unless `endsAfterScript` ends it right after the script, for that reason. Like the real sources, the first reason
/// a run ends for is the one `endReason()` reports. Calls are counted so tests can see what the mixer did, and a
/// `StartLatch` can hold `start()` halfway.
private actor FakeSource: AudioCaptureSource {
    struct StartFailure: Error, Equatable {}

    private let script: [[Float]]
    private let endsAfterScript: CaptureEndReason?
    private let failsToStart: Bool
    private let startLatch: StartLatch?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var lastEndReason: CaptureEndReason?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        script: [[Float]] = [], endsAfterScript: CaptureEndReason? = nil, failsToStart: Bool = false,
        startLatch: StartLatch? = nil
    ) {
        self.script = script
        self.endsAfterScript = endsAfterScript
        self.failsToStart = failsToStart
        self.startLatch = startLatch
    }

    /// Whether a stream handed out by `start()` is still open.
    var isRunning: Bool { continuation != nil }

    func start() async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        await startLatch?.park()
        if failsToStart { throw StartFailure() }
        end(.stopped)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(50))
        for (index, samples) in script.enumerated() {
            continuation.yield(AudioChunk(samples: samples, sequence: UInt64(index)))
        }
        self.continuation = continuation
        lastEndReason = nil
        if let reason = endsAfterScript {
            end(reason)
        }
        return stream
    }

    func stop() async {
        stopCount += 1
        end(.stopped)
    }

    func endReason() -> CaptureEndReason? {
        isRunning ? nil : lastEndReason
    }

    /// Ends the open stream, if any, for `reason`.
    private func end(_ reason: CaptureEndReason) {
        guard let continuation else { return }
        self.continuation = nil
        lastEndReason = reason
        continuation.finish()
    }
}

/// What a test read from a stream.
private struct Received {
    var chunks: [AudioChunk] = []
    /// Whether the stream ended, as opposed to the read stopping at its limit or timing out.
    var finished = false
}

/// Reads `stream` until it ends, `limit` chunks have arrived or `timeout` has passed, whichever comes first. The
/// timeout keeps a broken source from hanging the test run.
private func receive(
    _ stream: AsyncStream<AudioChunk>, limit: Int = .max, timeout: Duration = .seconds(5)
) async -> Received {
    await withTaskGroup(of: Received?.self) { group in
        group.addTask {
            var received = Received()
            var iterator = stream.makeAsyncIterator()
            while received.chunks.count < limit {
                guard let chunk = await iterator.next() else {
                    received.finished = !Task.isCancelled
                    return received
                }
                received.chunks.append(chunk)
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        // The reader's result. After a timeout, what it had read by the time it was cancelled.
        var outcome = Received()
        for await result in group {
            group.cancelAll()
            if let result {
                outcome = result
                break
            }
        }
        return outcome
    }
}

/// Checks `condition` every 10 ms until it holds or `timeout` passes, for effects that land on another task.
private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// One chunk's worth of `value`.
private func chunkSamples(_ value: Float) -> [Float] {
    [Float](repeating: value, count: AudioChunk.samplesPerChunk)
}

/// Whether `chunk` is a whole chunk of `value` (within float rounding).
private func isConstantChunk(_ chunk: AudioChunk, _ value: Float) -> Bool {
    chunk.samples.count == AudioChunk.samplesPerChunk && chunk.samples.allSatisfy { abs($0 - value) < 1e-6 }
}

// MARK: - Tests

@Suite("MixedSource", .timeLimit(.minutes(1)))
struct MixedSourceTests {
    @Test func mixesBothSources() async throws {
        let first = FakeSource(script: [chunkSamples(0.25), chunkSamples(0.25)])
        let second = FakeSource(script: [chunkSamples(0.25), chunkSamples(0.25)])
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream, limit: 2)
        await mixed.stop()
        let rest = await receive(stream)

        #expect(received.chunks.count == 2)
        #expect(received.chunks.allSatisfy { isConstantChunk($0, 0.5) })
        #expect(received.chunks.map(\.sequence) == [0, 1])
        #expect(rest.finished)
        #expect(rest.chunks.isEmpty)
        #expect(await first.isRunning == false)
        #expect(await second.isRunning == false)
    }

    @Test func finishesWhenOneFinishes() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)], endsAfterScript: .failed("first ended"))
        let second = FakeSource()  // yields nothing and never finishes on its own
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await second.startCount == 1)
        #expect(await second.stopCount == 1)
        #expect(await second.isRunning == false)
        #expect(await mixed.endReason() == .failed("first ended"))
    }

    @Test func secondSourceEndingFinishesTheMix() async throws {
        let first = FakeSource()  // yields nothing and never finishes on its own
        let second = FakeSource(script: [chunkSamples(0.25)], endsAfterScript: .failed("Microphone kept changing"))
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await first.stopCount == 1)
        #expect(await first.isRunning == false)
        #expect(await mixed.endReason() == .failed("Microphone kept changing"))
    }

    @Test func restartAfterStop() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)])
        let second = FakeSource(script: [chunkSamples(0.25)])
        let mixed = MixedSource(first: first, second: second)

        let firstRun = try await mixed.start()
        let fromFirstRun = await receive(firstRun, limit: 1)
        await mixed.stop()
        await mixed.stop()  // a second stop is harmless
        let endOfFirstRun = await receive(firstRun)

        let secondRun = try await mixed.start()
        let fromSecondRun = await receive(secondRun, limit: 1)
        await mixed.stop()

        #expect(fromFirstRun.chunks.count == 1)
        #expect(endOfFirstRun.finished)
        #expect(fromSecondRun.chunks.count == 1)
        #expect(fromSecondRun.chunks.allSatisfy { isConstantChunk($0, 0.5) })
        #expect(fromSecondRun.chunks.map(\.sequence) == [0])
        #expect(await first.startCount == 2)
        #expect(await second.startCount == 2)
    }

    @Test func startWhileRunningReplacesTheRun() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)])
        let second = FakeSource(script: [chunkSamples(0.25)])
        let mixed = MixedSource(first: first, second: second)

        let oldRun = try await mixed.start()
        let newRun = try await mixed.start()
        let endOfOldRun = await receive(oldRun)
        let fromNewRun = await receive(newRun, limit: 1)
        await mixed.stop()

        #expect(endOfOldRun.finished)
        #expect(fromNewRun.chunks.count == 1)
        #expect(fromNewRun.chunks.map(\.sequence) == [0])
        #expect(await first.startCount == 2)
        #expect(await first.stopCount == 2)
        #expect(await second.isRunning == false)
    }

    @Test func stopsFirstWhenSecondFailsToStart() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)])
        let second = FakeSource(failsToStart: true)
        let mixed = MixedSource(first: first, second: second)

        await #expect(throws: FakeSource.StartFailure.self) {
            _ = try await mixed.start()
        }
        #expect(await first.startCount == 1)
        #expect(await first.isRunning == false)
    }

    @Test func stopDuringStartWaitsForItAndWins() async throws {
        let latch = StartLatch()
        let first = FakeSource(script: [chunkSamples(0.25)], startLatch: latch)
        let second = FakeSource(script: [chunkSamples(0.25)])
        let mixed = MixedSource(first: first, second: second)

        let starting = Task { try await mixed.start() }
        await latch.waitForArrival()  // start() is now inside first.start(), parked
        let stopping = Task { await mixed.stop() }
        // Gives stop() time to reach the actor while start() is parked. Without the ordering it would find nothing
        // to stop, and the run that start() then sets up would keep going.
        try await Task.sleep(for: .milliseconds(100))
        await latch.open()

        let stream = try await starting.value
        await stopping.value
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await first.isRunning == false)
        #expect(await second.isRunning == false)
        #expect(await mixed.endReason() == .stopped)
    }

    @Test func consumerCancellingReleasesBothSources() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)])
        let second = FakeSource(script: [chunkSamples(0.25)])
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value

        // The release happens on the source's own schedule; its end reason is set once both sources are stopped.
        #expect(await eventually { await mixed.endReason() == .stopped })
        #expect(await first.isRunning == false)
        #expect(await second.isRunning == false)
    }

    // MARK: End reasons

    @Test func endReasonIsNilUntilARunEnds() async throws {
        let mixed = MixedSource(first: FakeSource(), second: FakeSource())

        let beforeStart = await mixed.endReason()
        let stream = try await mixed.start()
        let whileRunning = await mixed.endReason()
        await mixed.stop()
        let afterStop = await mixed.endReason()
        let rest = await receive(stream)  // also keeps the stream alive until here: dropping it would end the run

        #expect(beforeStart == nil)
        #expect(whileRunning == nil)
        #expect(afterStop == .stopped)
        #expect(rest.finished)
    }

    @Test func userStopOfOneSourceIsReported() async throws {
        let first = FakeSource(script: [chunkSamples(0.25)], endsAfterScript: .stoppedByUser)
        let second = FakeSource()
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await mixed.endReason() == .stoppedByUser)
        #expect(await second.isRunning == false)
    }

    @Test func userStopOutranksAFailure() async throws {
        let first = FakeSource(endsAfterScript: .failed("display went away"))
        let second = FakeSource(endsAfterScript: .stoppedByUser)
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await mixed.endReason() == .stoppedByUser)
    }
}
