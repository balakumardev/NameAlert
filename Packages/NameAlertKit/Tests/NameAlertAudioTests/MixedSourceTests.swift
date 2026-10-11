import NameAlertAudio
import NameAlertCore
import Testing

// MARK: - Helpers

/// A capture source that hands out scripted chunks, so `MixedSource` can be tested without audio hardware.
///
/// Every `start()` returns a fresh stream that already holds the script. The stream then stays open until `stop()`,
/// unless `finishesAfterScript` ends it right after the script. Calls are counted so tests can see what the mixer did.
private actor FakeSource: AudioCaptureSource {
    struct StartFailure: Error, Equatable {}

    private let script: [[Float]]
    private let finishesAfterScript: Bool
    private let failsToStart: Bool
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(script: [[Float]] = [], finishesAfterScript: Bool = false, failsToStart: Bool = false) {
        self.script = script
        self.finishesAfterScript = finishesAfterScript
        self.failsToStart = failsToStart
    }

    /// Whether a stream handed out by `start()` is still open.
    var isRunning: Bool { continuation != nil }

    func start() async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        if failsToStart { throw StartFailure() }
        continuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(50))
        for (index, samples) in script.enumerated() {
            continuation.yield(AudioChunk(samples: samples, sequence: UInt64(index)))
        }
        if finishesAfterScript {
            continuation.finish()
            self.continuation = nil
        } else {
            self.continuation = continuation
        }
        return stream
    }

    func stop() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
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
        let first = FakeSource(script: [chunkSamples(0.25)], finishesAfterScript: true)
        let second = FakeSource()  // yields nothing and never finishes on its own
        let mixed = MixedSource(first: first, second: second)

        let stream = try await mixed.start()
        let received = await receive(stream)

        #expect(received.finished)
        #expect(await second.startCount == 1)
        #expect(await second.stopCount == 1)
        #expect(await second.isRunning == false)
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
}
