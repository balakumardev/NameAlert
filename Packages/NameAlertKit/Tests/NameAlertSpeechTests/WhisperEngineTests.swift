import AVFoundation
import Foundation
import NameAlertAudio
import NameAlertCore
@testable import NameAlertSpeech  // the decode settings, the output cleanup and the lag estimate are internal
import Testing
import whisper

// MARK: - Helpers

/// Where the integration tests keep the real models, so they are downloaded once and not on every run.
private let cachedModelsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NameAlertTests/Models", isDirectory: true)

private let runsIntegration = ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1"

/// A new empty folder, removed again by `removeFolder`.
private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("NameAlertWhisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func removeFolder(_ folder: URL) {
    try? FileManager.default.removeItem(at: folder)
}

/// `sentence` read by the system voice, as 16 kHz mono samples, followed by a second of silence.
private func spokenSamples(_ sentence: String) throws -> [Float] {
    let folder = try makeTemporaryFolder()
    defer { removeFolder(folder) }
    let file = folder.appendingPathComponent("speech.aiff")

    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", file.path, sentence]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0)

    let audio = try AVAudioFile(forReading: file)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
    try audio.read(into: buffer)
    let speech = AudioFormatConverter().convert(buffer)
    try #require(!speech.isEmpty)
    return speech + [Float](repeating: 0, count: Int(AudioChunk.sampleRate))
}

/// The samples as numbered 100 ms chunks, the way a capture source delivers them. The last one is padded with silence.
private func chunks(of samples: [Float]) -> [AudioChunk] {
    let size = AudioChunk.samplesPerChunk
    return stride(from: 0, to: samples.count, by: size).enumerated().map { number, start in
        var piece = Array(samples[start..<min(start + size, samples.count)])
        piece += [Float](repeating: 0, count: size - piece.count)
        return AudioChunk(samples: piece, sequence: UInt64(number))
    }
}

/// The largest the test process has been in memory so far, in megabytes.
private func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
}

/// Has the Light English model (downloaded once into the test cache) transcribe `sentence`, spoken by the system
/// voice, with `hints` as the names to listen for. Prints what it heard and how long it took.
private func transcribe(_ sentence: String, hints: [String]) async throws -> [String] {
    let models = ModelManager(directory: cachedModelsDirectory)
    try await models.download(.lightEnglish) { _ in }
    try await models.download(.vad) { _ in }

    let samples = try spokenSamples(sentence)
    let engine = WhisperEngine(size: .light, modelManager: models)
    let loadStarted = ContinuousClock.now
    try await engine.prepare(localeIdentifier: "en-US", hints: hints, progress: { _ in })
    let loadTime = ContinuousClock.now - loadStarted

    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    for chunk in chunks(of: samples) { input.yield(chunk) }
    input.finish()

    let started = ContinuousClock.now
    var heard: [String] = []
    for try await update in engine.transcribe(audio) {
        #expect(update.isFinal)
        #expect(update.alternatives.isEmpty)
        #expect(update.segmentID.hasPrefix("w"))
        heard.append(update.text)
    }
    let processing = ContinuousClock.now - started
    await engine.stop()

    let audioSeconds = Double(samples.count) / AudioChunk.sampleRate
    print(
        """
        [whisper] heard \(heard) for "\(sentence)"; \(String(format: "%.2f", audioSeconds)) s of audio \
        processed in \(processing) (model load \(loadTime)); peak memory \(String(format: "%.0f", peakMemoryMB())) MB
        """)
    return heard
}

/// Whether any word in `texts` counts as `name` at Balanced sensitivity.
private func mentions(_ name: String, in texts: [String]) -> Bool {
    texts.flatMap(TextNormalizer.tokens).contains { Sensitivity.balanced.matches(term: name, heard: $0) }
}

// MARK: - Tests

@Suite("WhisperEngine", .serialized)
struct WhisperEngineTests {
    // MARK: Decode settings

    @Test func optionsAudioCtx() {
        #expect(WhisperOptions.audioContext(seconds: 2) == 256)
        #expect(WhisperOptions.audioContext(seconds: 6) == 364)
        #expect(WhisperOptions.audioContext(seconds: 40) == 1_500)
        // A segment of the longest kind (188 frames of 512 samples, 6.016 s) still fits with room to spare.
        #expect(WhisperOptions.audioContext(seconds: Double(188 * 512) / 16_000) == 365)
    }

    @Test func optionsPromptTruncates() throws {
        let hints = (0..<60).map { "Name\($0)" }
        let prompt = try #require(WhisperOptions.prompt(hints: hints))
        #expect(prompt.count <= 200)
        #expect(!prompt.hasSuffix(","))
        #expect(!prompt.hasSuffix(" "))
        // Whole names from the start, cut where the next whole name would not fit.
        let kept = prompt.components(separatedBy: ", ")
        #expect(kept == Array(hints.prefix(kept.count)))
        #expect((kept + [hints[kept.count]]).joined(separator: ", ").count > 200)

        #expect(WhisperOptions.prompt(hints: ["Bala", " Priya "]) == "Bala, Priya")
        #expect(WhisperOptions.prompt(hints: []) == nil)
        #expect(WhisperOptions.prompt(hints: ["  ", ""]) == nil)
    }

    @Test func optionsLanguage() {
        #expect(WhisperOptions.language(localeIdentifier: "en-US", englishOnlyModel: false) == "en")
        #expect(WhisperOptions.language(localeIdentifier: "de-DE", englishOnlyModel: false) == "de")
        #expect(WhisperOptions.language(localeIdentifier: "pt_BR", englishOnlyModel: false) == "pt")
        #expect(WhisperOptions.language(localeIdentifier: "zh-Hans-CN", englishOnlyModel: false) == "zh")
        #expect(WhisperOptions.language(localeIdentifier: "FR@calendar=gregorian", englishOnlyModel: false) == "fr")
        // The English-only models only know English.
        #expect(WhisperOptions.language(localeIdentifier: "en-GB", englishOnlyModel: true) == "en")
    }

    @Test func optionsThreads() {
        #expect(WhisperOptions.threads(processorCount: 12) == 4)
        #expect(WhisperOptions.threads(processorCount: 5) == 3)
        #expect(WhisperOptions.threads(processorCount: 2) == 1)
        #expect(WhisperOptions.threads(processorCount: 1) == 1)
    }

    @Test func optionsFillWhisperParameters() {
        let options = WhisperOptions(language: "en", prompt: "Bala", audioSeconds: 6, processorCount: 12)
        #expect(options.audioContext == 364)
        #expect(options.threads == 4)

        var params = whisper_full_params()
        options.apply(to: &params)
        #expect(params.strategy == WHISPER_SAMPLING_GREEDY)
        #expect(params.greedy.best_of == 1)
        #expect(params.n_threads == 4)
        #expect(params.audio_ctx == 364)
        #expect(params.no_context)
        #expect(params.no_timestamps)
        #expect(!params.single_segment)
        #expect(!params.translate)
        #expect(!params.detect_language)
        #expect(!params.print_special && !params.print_progress && !params.print_realtime && !params.print_timestamps)
        #expect(params.suppress_blank)
        #expect(params.suppress_nst)
        #expect(params.temperature == 0)
        #expect(params.temperature_inc == 0)
        #expect(params.no_speech_thold == 0.6)
        #expect(!params.vad)  // the engine runs its own speech detection
        // The C strings are set by the context, for exactly as long as the decode runs.
        #expect(params.language == nil)
        #expect(params.initial_prompt == nil)
    }

    // MARK: Output

    @Test func outputDropsNoSpeechAndNotes() {
        func text(_ parts: (String, Float)...) -> String? {
            WhisperOutput.text(of: parts.map { WhisperSegment(text: $0.0, noSpeechProbability: $0.1) })
        }
        #expect(text((" Hey Bala, can you share your screen?", 0.05)) == "Hey Bala, can you share your screen?")
        #expect(text((" Hey Bala", 0.1), (" are you there?", 0.1)) == "Hey Bala are you there?")
        // Every part says there was no speech: whisper is likely repeating its prompt over silence.
        #expect(text((" Bala", 0.7)) == nil)
        #expect(text((" Bala", 0.7), (" Bala", 0.65)) == nil)
        // One part that heard speech keeps the segment.
        #expect(text((" Bala", 0.7), (" hello", 0.2)) == "Bala hello")
        // Notes about non-speech go, and so does a segment with nothing else in it.
        #expect(text((" [BLANK_AUDIO]", 0.1)) == nil)
        #expect(text((" (music)", 0.1), ("[Music]", 0.1)) == nil)
        #expect(text((" (silence) Bala [Music]  is here (laughs)", 0.1)) == "Bala is here")
        #expect(text((" ♪ ", 0.1)) == nil)
        #expect(text() == nil)
    }

    // MARK: Falling behind

    @Test func liveLagMeasuresQueuedAudio() {
        var lag = LiveLag()
        // The engine waited for these: they are live.
        #expect(lag.update(sequence: 0, at: 100, waited: true) == 0)
        #expect(lag.update(sequence: 1, at: 100.1, waited: true) == 0)
        // Earlier than its time without waiting is live too (chunk 2 is due at 100.2).
        #expect(lag.update(sequence: 2, at: 100.15, waited: false) == 0)
        // The engine was busy for 12 s. The chunks that queued up meanwhile are read back to back, each one later
        // than its time (now measured from chunk 2: chunk 3 was due at 100.25, chunk 4 at 100.35).
        #expect(abs(lag.update(sequence: 3, at: 112.2, waited: false) - 11.95) < 1e-6)
        #expect(abs(lag.update(sequence: 4, at: 112.2, waited: false) - 11.85) < 1e-6)
        // The source dropped the chunks that did not fit in its buffer: the numbering jumps, so the gap counts as
        // time that passed. Chunk 123 is due at 112.25, so at 112.2 it is live again...
        #expect(lag.update(sequence: 123, at: 112.2, waited: false) == 0)
        // ...and the next one, due at 112.3, is read a second late.
        #expect(abs(lag.update(sequence: 124, at: 113.3, waited: false) - 1.0) < 1e-6)
        // A new run numbers from 0 again.
        #expect(lag.update(sequence: 0, at: 200, waited: false) == 0)
    }

    // MARK: Engine

    @Test func prepareThrowsWhenModelMissing() async throws {
        let folder = try makeTemporaryFolder()
        defer { removeFolder(folder) }
        let engine = WhisperEngine(size: .light, modelManager: ModelManager(directory: folder))
        #expect(engine.id == .whisperLight)
        await #expect(throws: SpeechEngineError.modelNotInstalled) {
            try await engine.prepare(localeIdentifier: "en-US", hints: ["Bala"], progress: { _ in })
        }
        #expect(WhisperEngine(size: .balanced, modelManager: ModelManager(directory: folder)).id == .whisperBalanced)
    }

    @Test func transcribeBeforePrepareFails() async throws {
        let folder = try makeTemporaryFolder()
        defer { removeFolder(folder) }
        let engine = WhisperEngine(size: .light, modelManager: ModelManager(directory: folder))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        input.yield(AudioChunk(samples: [Float](repeating: 0, count: AudioChunk.samplesPerChunk), sequence: 0))
        await #expect(throws: SpeechEngineError.self) {
            for try await _ in engine.transcribe(audio) {}
        }
        // Stopping an engine that is not running does nothing, as often as it is asked.
        await engine.stop()
        await engine.stop()
    }

    // MARK: Real model

    @Test(
        "Hears a name in speech",
        .enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to download and run the real model."))
    func detectsNameInSpeech() async throws {
        let heard = try await transcribe("Hey Bala, can you share your screen please?", hints: ["Bala"])
        #expect(mentions("bala", in: heard))
    }

    @Test(
        "Does not hear the name in other speech",
        .enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to download and run the real model."))
    func noFalseNameInOtherSpeech() async throws {
        let heard = try await transcribe("The weather is lovely today and the coffee is hot.", hints: ["Bala"])
        // It did hear the sentence, so the name's absence means something.
        let words = Set(heard.flatMap(TextNormalizer.tokens))
        #expect(!words.isDisjoint(with: ["weather", "lovely", "today", "coffee", "hot"]))
        #expect(!mentions("bala", in: heard))
    }
}
