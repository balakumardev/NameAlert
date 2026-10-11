import AVFoundation
import CoreMedia
import Foundation
import NameAlertCore
@testable import NameAlertSpeech  // the failing engine, the audio conversion and the result mapping are internal
import Speech
import Testing
import os

// MARK: - Helpers

private let runsIntegration = ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1"

/// A model manager for a folder that does not exist: nothing is downloaded by these tests.
private func unusedModelManager() -> ModelManager {
    ModelManager(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertFactory-\(UUID().uuidString)", isDirectory: true))
}

/// Collects the progress `prepare` reports.
private final class PreparationLog: Sendable {
    private let storage = OSAllocatedUnfairLock<[PreparationProgress]>(initialState: [])

    func record(_ progress: PreparationProgress) { storage.withLock { $0.append(progress) } }
    var values: [PreparationProgress] { storage.withLock { $0 } }
}

/// Has a new engine with `module` prepare for US English, with the hint "Bala", and transcribe `sentence` read by the
/// system voice. Prints what it heard, how long that took, and whether speech recognition had been allowed.
@available(macOS 26, *)
private func transcribe(_ module: AppleAnalyzerEngine.Module, _ sentence: String) async throws -> [TranscriptUpdate] {
    let samples = try SpeechFixture.spokenSamples(sentence)
    let engine = AppleAnalyzerEngine(module: module)
    let progress = PreparationLog()
    let clock = ContinuousClock()
    let started = clock.now
    try await engine.prepare(localeIdentifier: "en-US", hints: ["Bala"], progress: { progress.record($0) })
    let prepared = clock.now
    var updates: [TranscriptUpdate] = []
    for try await update in engine.transcribe(SpeechFixture.stream(of: samples)) {
        updates.append(update)
    }
    let finished = clock.now
    await engine.stop()

    let audioSeconds = Double(samples.count) / AudioChunk.sampleRate
    print(
        """
        [\(module)] speech permission \(SpeechPermission.status()); prepare took \(prepared - started), asset \
        progress \(progress.values.map(\.fraction)); \(String(format: "%.2f", audioSeconds)) s of audio transcribed in \
        \(finished - prepared); updates: \(SpeechFixture.describe(updates))
        """)

    #expect(updates.allSatisfy { $0.segmentID.hasPrefix("sa") })
    #expect(updates.last?.isFinal == true)
    // A volatile result and the final one for the same audio share their ID, so every segment ends final.
    let lastOfEachSegment = Dictionary(updates.map { ($0.segmentID, $0) }, uniquingKeysWith: { $1 })
    #expect(lastOfEachSegment.values.allSatisfy { $0.isFinal }, "a segment was left volatile")
    return updates
}

// MARK: - Tests

@Suite("AppleAnalyzer")
struct AppleAnalyzerEngineTests {
    // MARK: Factory

    @Test func factoryMapsIDs() {
        let models = unusedModelManager()
        func make(_ id: EngineID) -> any SpeechEngine {
            SpeechEngineFactory.make(id, modelManager: models, onFallingBehind: {})
        }
        for id in EngineID.allCases {
            #expect(make(id).id == id)
        }
        #expect(make(.appleSFSpeech) is AppleSFSpeechEngine)
        #expect(make(.whisperLight) is WhisperEngine)
        #expect(make(.whisperBalanced) is WhisperEngine)
        if #available(macOS 26, *) {
            #expect(make(.appleSpeechTranscriber) is AppleAnalyzerEngine)
            #expect(make(.appleDictationTranscriber) is AppleAnalyzerEngine)
        } else {
            #expect(make(.appleSpeechTranscriber) is FailingEngine)
            #expect(make(.appleDictationTranscriber) is FailingEngine)
        }
    }

    @Test func failingEngineSaysWhy() async {
        // What the factory gives for SpeechAnalyzer's engines before macOS 26.
        let engine = FailingEngine(id: .appleDictationTranscriber, error: .engineFailed("Requires macOS 26"))
        #expect(engine.id == .appleDictationTranscriber)
        await #expect(throws: SpeechEngineError.engineFailed("Requires macOS 26")) {
            try await engine.prepare(localeIdentifier: "en-US", hints: [], progress: { _ in })
        }
        await #expect(throws: SpeechEngineError.engineFailed("Requires macOS 26")) {
            for try await _ in engine.transcribe(SpeechFixture.stream(of: [Float](repeating: 0, count: 1_600))) {}
        }
        await engine.updateHints(["Bala"])
        await engine.stop()
    }

    // MARK: Audio and results

    @Test func audioIsConvertedToTheAnalyzerFormat() throws {
        // What the analyzer asks for on macOS 27: 16 kHz mono Int16.
        let int16 = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let toInt16 = try #require(AnalyzerAudio(analyzerFormat: int16))
        let converted = try #require(toInt16.convert([0, 0.5, -0.5, 1]))
        #expect(converted.format.commonFormat == .pcmFormatInt16)
        #expect(converted.format.sampleRate == 16_000)
        #expect(converted.frameLength == 4)
        let channel = try #require(converted.int16ChannelData?[0])
        let values = Array(UnsafeBufferPointer(start: channel, count: 4)).map(Int.init)
        for (value, expected) in zip(values, [0, 16_384, -16_384, 32_767]) {
            #expect(abs(value - expected) <= 1, "\(values)")
        }
        #expect(toInt16.convert([]) == nil)

        // The app's own format passes straight through.
        let float32 = try #require(MonoAudio.makeFormat())
        let same = try #require(AnalyzerAudio(analyzerFormat: float32))
        let passed = try #require(same.convert([0.25, -0.25]))
        let samples = try #require(passed.floatChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: samples, count: Int(passed.frameLength))) == [0.25, -0.25])
        // With no format to go by, so does every chunk.
        #expect(AnalyzerAudio(analyzerFormat: nil)?.convert([0.5])?.format.commonFormat == .pcmFormatFloat32)
    }

    @Test func updatesFromAnalyzerResults() {
        // The segment is the start of the result's audio in milliseconds; the text loses the space before it.
        let start = CMTime(value: 25_920, timescale: 24_000)  // 1.08 s
        #expect(
            AnalyzerTranscript.update(
                text: " can you share your", alternatives: [" can you share your", " can you share you're"],
                start: start, isFinal: true)
                == TranscriptUpdate(
                    segmentID: "sa1080", text: "can you share your", alternatives: ["can you share you're"],
                    isFinal: true))
        let late = CMTime(value: 2_999, timescale: 10_000)  // 0.2999 s: the milliseconds are cut, not rounded
        #expect(AnalyzerTranscript.update(text: "hey", alternatives: [], start: late, isFinal: false)?.segmentID == "sa299")
        #expect(AnalyzerTranscript.update(text: "hey", alternatives: [], start: .invalid, isFinal: false)?.segmentID == "sa0")
        // An empty volatile result says nothing. An empty final one clears what came before it.
        #expect(AnalyzerTranscript.update(text: " ", alternatives: [], start: .zero, isFinal: false) == nil)
        #expect(
            AnalyzerTranscript.update(text: "", alternatives: [], start: .zero, isFinal: true)
                == TranscriptUpdate(segmentID: "sa0", text: "", isFinal: true))
    }

    // MARK: The engine (macOS 26 and later)

    @available(macOS 26, *)
    @Test func transcribeBeforePrepareFails() async {
        let engine = AppleAnalyzerEngine(module: .speechTranscriber)
        #expect(engine.id == .appleSpeechTranscriber)
        #expect(AppleAnalyzerEngine(module: .dictationTranscriber).id == .appleDictationTranscriber)
        await #expect(throws: SpeechEngineError.self) {
            for try await _ in engine.transcribe(SpeechFixture.stream(of: [Float](repeating: 0, count: 1_600))) {}
        }
        // Stopping an engine that is not running does nothing, as often as it is asked.
        await engine.stop()
        await engine.stop()
    }

    @available(macOS 26, *)
    @Test func prepareRefusesALanguageItDoesNotHave() async {
        let engine = AppleAnalyzerEngine(module: .dictationTranscriber)
        await #expect(throws: SpeechEngineError.unsupportedLocale("zz-ZZ")) {
            try await engine.prepare(localeIdentifier: "zz-ZZ", hints: [], progress: { _ in })
        }
    }

    // MARK: Apple's speech analyzer

    @available(macOS 26, *)
    @Test(.enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to run Apple's speech analyzer."))
    func liveTranscription() async throws {
        let updates = try await transcribe(.speechTranscriber, "Hey Bala, can you share your screen please?")
        #expect(SpeechFixture.finalWords(updates).contains("bala"))
    }

    @available(macOS 26, *)
    @Test(
        .enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to run Apple's speech analyzer."),
        .timeLimit(.minutes(1)))
    func liveSecondTranscriptionAndStop() async throws {
        let samples = try SpeechFixture.spokenSamples("Hey Bala, can you share your screen please?")
        let engine = AppleAnalyzerEngine(module: .speechTranscriber)
        try await engine.prepare(localeIdentifier: "en-US", hints: ["Bala"], progress: { _ in })
        // The first transcription uses the analyzer `prepare` loaded.
        for try await _ in engine.transcribe(SpeechFixture.stream(of: samples)) {}

        // The second one needs a new analyzer. Its audio does not end, as a capture source's does not: the speech, 2 s
        // of silence, and the stream stays open.
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in SpeechFixture.chunks(of: samples + [Float](repeating: 0, count: 32_000)) { input.yield(chunk) }
        var updates = engine.transcribe(audio).makeAsyncIterator()
        var heard: [TranscriptUpdate] = []
        func hearsTheName(_ update: TranscriptUpdate) -> Bool { TextNormalizer.tokens(update.text).contains("bala") }
        while let update = try await updates.next() {
            heard.append(update)
            if hearsTheName(update) { break }
        }
        #expect(heard.contains(where: hearsTheName))

        // `stop` ends it at once, without an error.
        let clock = ContinuousClock()
        let started = clock.now
        await engine.stop()
        while try await updates.next() != nil {}
        let took = clock.now - started
        print("[stop] the second transcription heard \(SpeechFixture.describe(heard)); stop took \(took)")
        #expect(took < .seconds(2))
        input.finish()
    }

    @available(macOS 26, *)
    @Test(.enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to run Apple's speech analyzer."))
    func liveDictation() async throws {
        // DictationTranscriber mishears the system voice's "Bala" ("Valhalla"), so this checks the rest of the
        // sentence: the module runs, end to end.
        let updates = try await transcribe(.dictationTranscriber, "Hey Bala, can you share your screen please?")
        let words = SpeechFixture.finalWords(updates)
        #expect(words.contains("share") && words.contains("screen"))
    }
}
