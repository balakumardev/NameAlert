import AVFoundation
import Foundation
import NameAlertCore
@testable import NameAlertSpeech  // the ring buffer, the rotation policy and the task bookkeeping are internal
import Speech
import Testing

// MARK: - Helpers

private let runsIntegration = ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1"

/// `seconds` of 16 kHz audio, in samples.
private func samples(seconds: Double) -> Int {
    Int((seconds * AudioChunk.sampleRate).rounded())
}

/// Chunk `n` of a test stream: 100 ms of samples that all hold the value `n`, so a test can see where audio went.
private func chunk(_ n: Int) -> [Float] {
    [Float](repeating: Float(n), count: AudioChunk.samplesPerChunk)
}

/// The chunks numbered `numbers`, one after the other.
private func audio(_ numbers: Range<Int>) -> [Float] {
    numbers.flatMap(chunk)
}

private typealias Action = SFSpeechSession.Action

/// A session behind a reference, so that a test can write `#expect(session.handle(...) == ...)`: `#expect` cannot take
/// a mutating call.
private final class Session {
    private var session = SFSpeechSession()
    var isDone: Bool { session.isDone }
    func start() -> [Action] { session.start() }
    func handle(_ event: SFSpeechSession.Event) -> [Action] { session.handle(event) }
}

private func heard(_ text: String, _ alternatives: [String] = [], final: Bool = false) -> SFSpeechSession.Recognized {
    SFSpeechSession.Recognized(text: text, alternatives: alternatives, isFinal: final)
}

private func report(_ generation: UInt64, _ text: String, _ alternatives: [String] = [], final: Bool = false) -> Action {
    .report(TranscriptUpdate(segmentID: "sf\(generation)", text: text, alternatives: alternatives, isFinal: final))
}

/// A started session that has been given `count` chunks of audio, numbered from 0.
private func session(fedChunks count: Int) -> Session {
    let session = Session()
    _ = session.start()
    for n in 0..<count { _ = session.handle(.audio(chunk(n))) }
    return session
}

private func startsATask(_ action: Action) -> Bool {
    if case .startTask = action { true } else { false }
}

// MARK: - Tests

@Suite("AppleSFSpeech")
struct AppleSFSpeechEngineTests {
    // MARK: Ring buffer and rotation policy

    @Test func ringBufferKeepsLast() {
        var ring = AudioRingBuffer()
        let values = (0..<30_000).map(Float.init)
        for start in stride(from: 0, to: values.count, by: AudioChunk.samplesPerChunk) {
            ring.append(Array(values[start..<min(start + AudioChunk.samplesPerChunk, values.count)]))
        }
        #expect(ring.count == 24_000)  // 1.5 s
        #expect(ring.contents == Array(values[6_000...]))

        // Until it is full it holds everything. A block longer than it leaves only the block's end.
        var small = AudioRingBuffer(capacity: 5)
        #expect(small.contents.isEmpty)
        small.append([1, 2, 3])
        #expect(small.contents == [1, 2, 3])
        small.append([])
        #expect(small.contents == [1, 2, 3])
        small.append([4, 5, 6, 7])
        #expect(small.contents == [3, 4, 5, 6, 7])
        small.append((10..<20).map(Float.init))
        #expect(small.contents == [15, 16, 17, 18, 19])
    }

    @Test func rotationPolicy() {
        var policy = RotationPolicy()
        // `#expect` cannot take a mutating call, so each answer is taken first.
        let at49_9 = policy.shouldRotate(after: .audio(samples: samples(seconds: 49.9)))
        let at50 = policy.shouldRotate(after: .audio(samples: samples(seconds: 0.1)))  // 50 s in this task
        let onFinal = policy.shouldRotate(after: .result(isFinal: true))
        let onPartial = policy.shouldRotate(after: .result(isFinal: false))
        let onFailure = policy.shouldRotate(after: .failure)
        #expect(!at49_9)
        #expect(at50)
        #expect(onFinal)
        #expect(!onPartial)
        #expect(onFailure)

        // A new task starts the count again ...
        policy.rotated()
        let afterRotation = policy.shouldRotate(after: .audio(samples: samples(seconds: 49.9)))
        #expect(!afterRotation)
        // ... from the audio it was primed with.
        policy.rotated(primedSamples: samples(seconds: 1.5))
        let primedAt48_4 = policy.shouldRotate(after: .audio(samples: samples(seconds: 48.4)))
        let primedAt48_5 = policy.shouldRotate(after: .audio(samples: samples(seconds: 0.1)))
        #expect(!primedAt48_4)
        #expect(primedAt48_5)
    }

    // MARK: Rotating the recognition tasks

    @Test func sessionFeedsTheCurrentTask() {
        let session = Session()
        #expect(session.handle(.audio(chunk(0))) == [], "nothing before it starts")
        #expect(session.start() == [.startTask(generation: 1, primer: [])])
        #expect(session.start() == [], "it starts once")
        #expect(session.handle(.audio(chunk(0))) == [.append(generation: 1, chunk(0))])
        #expect(session.handle(.audio([])) == [])
    }

    @Test func sessionRotatesAfter50SecondsOfAudio() {
        let session = session(fedChunks: 499)  // 49.9 s
        // The 500th chunk makes 50 s. The next task starts with the last 1.5 s (chunks 485 to 499) before the
        // current one is told its audio has ended; that one is cancelled 2 s later.
        #expect(
            session.handle(.audio(chunk(499))) == [
                .append(generation: 1, chunk(499)),
                .startTask(generation: 2, primer: audio(485..<500)),
                .endAudio(generation: 1),
                .scheduleRetirement(generation: 1, after: .seconds(2)),
            ])
        #expect(session.handle(.audio(chunk(500))) == [.append(generation: 2, chunk(500))])

        // Task 1 still reports its last words, under its own ID, and then it can go.
        #expect(
            session.handle(.result(generation: 1, heard("hey bala", final: true))) == [
                report(1, "hey bala", final: true), .cancel(generation: 1),
            ])
        #expect(session.handle(.retireDue(generation: 1)) == [], "already gone")
        #expect(session.handle(.result(generation: 1, heard("late"))) == [], "nothing counts after the cancel")

        // Task 2 counts its 1.5 s primer: 48.5 s of new audio make its 50 s.
        var actions: [Action] = []
        for n in 501..<984 { actions += session.handle(.audio(chunk(n))) }
        #expect(!actions.contains(where: startsATask))
        #expect(
            session.handle(.audio(chunk(984))) == [
                .append(generation: 2, chunk(984)),
                .startTask(generation: 3, primer: audio(970..<985)),
                .endAudio(generation: 2),
                .scheduleRetirement(generation: 2, after: .seconds(2)),
            ])
    }

    @Test func aRetiredTaskEndsItsSegment() {
        let session = session(fedChunks: 500)  // task 1 is retiring, task 2 is current
        #expect(
            session.handle(.result(generation: 1, heard("hey bala", ["hey bella"])))
                == [report(1, "hey bala", ["hey bella"])])
        // It never says its last word. When its time is up, its last reading is reported again as final.
        #expect(
            session.handle(.retireDue(generation: 1)) == [
                report(1, "hey bala", ["hey bella"], final: true), .cancel(generation: 1),
            ])
        #expect(session.handle(.retireDue(generation: 2)) == [], "the current task is not retired")
    }

    @Test func sessionReportsEachTaskUnderItsOwnID() {
        let session = session(fedChunks: 3)
        #expect(session.handle(.result(generation: 1, heard("hey", ["hay"]))) == [report(1, "hey", ["hay"])])
        #expect(session.handle(.result(generation: 1, heard(""))) == [], "an empty reading says nothing")
        #expect(session.handle(.result(generation: 9, heard("who"))) == [], "no such task")
        // A final result means the task is done: the next one starts at once, with the last 1.5 s.
        #expect(
            session.handle(.result(generation: 1, heard("hey bala", final: true))) == [
                report(1, "hey bala", final: true), .cancel(generation: 1),
                .startTask(generation: 2, primer: audio(0..<3)),
            ])
        #expect(session.handle(.result(generation: 2, heard("can you"))) == [report(2, "can you")])
        // An empty final after text clears it.
        #expect(
            session.handle(.result(generation: 2, heard("", final: true))) == [
                report(2, "", final: true), .cancel(generation: 2), .startTask(generation: 3, primer: audio(0..<3)),
            ])
    }

    @Test func aFailedTaskIsReplaced() {
        let session = session(fedChunks: 30)  // 3 s: more than a quick failure
        _ = session.handle(.result(generation: 1, heard("hey bala")))
        // Its last reading becomes final, and the next task starts with the last 1.5 s.
        #expect(
            session.handle(.failure(generation: 1, reason: "timeout")) == [
                report(1, "hey bala", final: true), .cancel(generation: 1),
                .startTask(generation: 2, primer: audio(15..<30)),
            ])
        #expect(session.handle(.failure(generation: 1, reason: "late")) == [], "task 1 is gone")
        #expect(!session.isDone)
    }

    @Test func threeQuickFailuresInARowEndTheTranscription() {
        let session = session(fedChunks: 0)
        // Each task fails at once, before it heard anything.
        #expect(
            session.handle(.failure(generation: 1, reason: "not allowed")) == [
                .cancel(generation: 1), .startTask(generation: 2, primer: []),
            ])
        _ = session.handle(.audio(chunk(0)))
        #expect(
            session.handle(.failure(generation: 2, reason: "not allowed")) == [
                .cancel(generation: 2), .startTask(generation: 3, primer: chunk(0)),
            ])
        #expect(
            session.handle(.failure(generation: 3, reason: "not allowed")) == [
                .cancel(generation: 3), .fail(.engineFailed("Apple speech recognition keeps failing (not allowed).")),
            ])
        #expect(session.isDone)
        #expect(session.handle(.audio(chunk(1))) == [])
        #expect(session.handle(.audioEnded) == [])
    }

    @Test func aTaskThatWorkedStartsTheCountAgain() {
        let session = session(fedChunks: 0)
        _ = session.handle(.failure(generation: 1, reason: "x"))
        _ = session.handle(.failure(generation: 2, reason: "x"))
        // Task 3 hears something before it fails, so the recognizer works ...
        _ = session.handle(.result(generation: 3, heard("hello")))
        _ = session.handle(.failure(generation: 3, reason: "x"))
        // ... and task 4 fails only after 2 s of audio.
        for n in 0..<20 { _ = session.handle(.audio(chunk(n))) }
        _ = session.handle(.failure(generation: 4, reason: "x"))
        // So it takes three quick failures from here to give up.
        _ = session.handle(.failure(generation: 5, reason: "x"))
        _ = session.handle(.failure(generation: 6, reason: "x"))
        #expect(!session.isDone)
        _ = session.handle(.failure(generation: 7, reason: "x"))
        #expect(session.isDone)
    }

    @Test func aNewTaskRefusedWhileTheOldOneFinishesTakesItsPlace() {
        let session = session(fedChunks: 500)  // task 1 is retiring, task 2 is current
        _ = session.handle(.result(generation: 1, heard("hey bala")))
        // Task 2 fails at once. The recognizer may run only one task at a time, so task 1 goes now and a new
        // task starts. This is not counted as a quick failure.
        #expect(
            session.handle(.failure(generation: 2, reason: "busy")) == [
                .cancel(generation: 2), report(1, "hey bala", final: true), .cancel(generation: 1),
                .startTask(generation: 3, primer: audio(485..<500)),
            ])
        _ = session.handle(.failure(generation: 3, reason: "busy"))
        _ = session.handle(.failure(generation: 4, reason: "busy"))
        #expect(!session.isDone)
        _ = session.handle(.failure(generation: 5, reason: "busy"))
        #expect(session.isDone)
    }

    // MARK: The end of the audio

    @Test func whenTheAudioEndsTheLastResultsAreAwaited() {
        let session = session(fedChunks: 2)
        _ = session.handle(.result(generation: 1, heard("hey")))
        #expect(session.handle(.audioEnded) == [.endAudio(generation: 1), .scheduleDrainTimeout(after: .seconds(10))])
        #expect(session.handle(.audio(chunk(2))) == [], "no audio after the end")
        #expect(session.handle(.audioEnded) == [])
        #expect(
            session.handle(.result(generation: 1, heard("hey bala", final: true))) == [
                report(1, "hey bala", final: true), .cancel(generation: 1), .finish,
            ])
        #expect(session.isDone)
        #expect(session.handle(.drainTimedOut) == [])
    }

    @Test func theEndWaitsForARetiringTaskToo() {
        let session = session(fedChunks: 500)  // task 1 is retiring, task 2 is current
        _ = session.handle(.result(generation: 1, heard("hey")))
        #expect(session.handle(.audioEnded) == [.endAudio(generation: 2), .scheduleDrainTimeout(after: .seconds(10))])
        // Task 2 had nothing to say. Task 1 still has its 2 s.
        #expect(session.handle(.failure(generation: 2, reason: "no speech")) == [.cancel(generation: 2)])
        #expect(!session.isDone)
        #expect(
            session.handle(.retireDue(generation: 1)) == [
                report(1, "hey", final: true), .cancel(generation: 1), .finish,
            ])
    }

    @Test func theEndDoesNotWaitForever() {
        let session = session(fedChunks: 2)
        _ = session.handle(.result(generation: 1, heard("hey")))
        _ = session.handle(.audioEnded)
        #expect(
            session.handle(.drainTimedOut) == [report(1, "hey", final: true), .cancel(generation: 1), .finish])
        #expect(session.isDone)
    }

    // MARK: Audio and text for the recognizer

    @Test func buffersHoldTheSamples() throws {
        let format = try #require(MonoAudio.makeFormat())
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
        let buffer = try #require(MonoAudio.buffer([0.25, -0.5, 1], format: format))
        #expect(buffer.frameLength == 3)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: channel, count: 3)) == [0.25, -0.5, 1])
        #expect(MonoAudio.buffer([], format: format) == nil)
    }

    @Test func readingsAreTidied() {
        #expect(Readings.text("  hey bala \n") == "hey bala")
        // At most three, best first: no blanks, no repeats, and not the text itself.
        #expect(
            Readings.alternatives(
                ["hey bala", " hey bella ", "", "hey bella", "hay bala", "a bala", "hey baler"], besides: "hey bala")
                == ["hey bella", "hay bala", "a bala"])
        #expect(Readings.alternatives([], besides: "hey").isEmpty)
    }

    // MARK: The engine

    @Test func prepareChecksTheLanguageAndThePermission() async {
        let engine = AppleSFSpeechEngine()
        #expect(engine.id == .appleSFSpeech)
        await #expect(throws: SpeechEngineError.unsupportedLocale("zz-ZZ")) {
            try await engine.prepare(localeIdentifier: "zz-ZZ", hints: [], progress: { _ in })
        }
        // English on the device, but speech recognition is not allowed: the engine says so and does not ask.
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .authorized,
            SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true
        {
            await #expect(throws: SpeechEngineError.permissionDenied) {
                try await engine.prepare(localeIdentifier: "en-US", hints: ["Bala"], progress: { _ in })
            }
            #expect(SFSpeechRecognizer.authorizationStatus() == status)
        }
    }

    @Test func transcribeBeforePrepareFails() async {
        let engine = AppleSFSpeechEngine()
        let updates = engine.transcribe(SpeechFixture.stream(of: [Float](repeating: 0, count: 1_600)))
        await #expect(throws: SpeechEngineError.self) {
            for try await _ in updates {}
        }
        // Stopping an engine that is not running does nothing, as often as it is asked.
        await engine.stop()
        await engine.stop()
    }

    // MARK: Apple's recognizer

    @Test(
        .enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to run Apple's recognizer."),
        .enabled(
            if: SFSpeechRecognizer.authorizationStatus() == .authorized,
            "Speech recognition is not allowed for this test process, and the test does not ask for it."))
    func liveTranscription() async throws {
        let samples = try SpeechFixture.spokenSamples("Hey Bala, can you share your screen please?")
        let engine = AppleSFSpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US", hints: ["Bala"], progress: { _ in })
        var updates: [TranscriptUpdate] = []
        for try await update in engine.transcribe(SpeechFixture.stream(of: samples)) {
            updates.append(update)
        }
        await engine.stop()
        print("[sfspeech] \(SpeechFixture.describe(updates))")

        #expect(updates.allSatisfy { $0.segmentID.hasPrefix("sf") })
        #expect(updates.last?.isFinal == true)
        #expect(SpeechFixture.finalWords(updates).contains("bala"))
    }
}
