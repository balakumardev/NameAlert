@testable import NameAlertAudio
import NameAlertCore
import Testing

/// Whether `stream` finishes, after any chunks it still holds, within `timeout`.
private func finishes(_ stream: AsyncStream<AudioChunk>, within timeout: Duration = .seconds(2)) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream {}
            return !Task.isCancelled
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

@Suite("RestartBudget")
struct RestartBudgetTests {
    @Test func allowsThreeRestartsInTenSeconds() {
        var budget = RestartBudget()
        let start = ContinuousClock.now
        let offsets: [Duration] = [
            .seconds(0), .seconds(1), .seconds(2),
            .seconds(3),  // a fourth within 10 s
            .milliseconds(9_999),  // still within 10 s of the first; refusals do not count...
            .seconds(10),  // ...so once the first restart is 10 s old, one fits again
            .seconds(10.5),  // restarts at 1, 2 and 10 s fill the window
            .seconds(11),  // the one at 1 s has aged out
        ]

        let answers = offsets.map { budget.allow(at: start + $0) }

        #expect(answers == [true, true, true, false, false, true, false, true])
    }
}

@Suite("ChunkOutput", .timeLimit(.minutes(1)))
struct ChunkOutputTests {
    @Test func firstEndReasonWins() async {
        let (stream, continuation) = ChunkStream.make()
        let output = ChunkOutput(stage: ChunkAssembler(), continuation: continuation)

        output.finish(reason: .failed("capture error"))
        output.finish(reason: .stopped)  // a stop after the failure does not change why the run ended
        let recordedLater = output.recordEnd(.stoppedByUser)

        #expect(output.recordedEndReason == .failed("capture error"))
        #expect(recordedLater == .failed("capture error"))
        #expect(await finishes(stream))
    }

    @Test func droppedOutputFinishesItsStream() async {
        let (stream, continuation) = ChunkStream.make()
        do {
            let output = ChunkOutput(stage: ChunkAssembler(), continuation: continuation)
            output.process { $0.push([Float](repeating: 0.5, count: AudioChunk.samplesPerChunk)) }
        }  // the last reference is gone: the backstop in deinit finishes the stream

        #expect(await finishes(stream))
    }
}
