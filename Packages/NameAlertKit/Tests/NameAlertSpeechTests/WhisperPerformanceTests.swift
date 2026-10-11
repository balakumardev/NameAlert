import AVFoundation
import Foundation
import NameAlertAudio
import NameAlertCore
import NameAlertSpeech
import Testing
import os

// Spec section 15, acceptance 7: the local model must stay under 500 MB and keep up with live speech after ten
// minutes of it. This runs the real Light and Balanced English models over ten minutes of speech read by the system
// voice, and measures what the process used. It runs only with NAMEALERT_INTEGRATION=1 (it downloads the Balanced
// model, about 60 MB, the first time) and it only means something when it has the process to itself, so
// `scripts/verify.sh` runs it on its own.
//
// What is measured, and how:
// - Memory is the process's physical footprint (`phys_footprint` from `task_info(TASK_VM_INFO)`, the number
//   Activity Monitor shows as "Memory"). A sampler reads it every 50 ms from before the model loads until the
//   transcription ends, and the largest reading counts. That is the test process, so the speech held in memory by the
//   test (about 40 MB) and the test runner itself count against the limit too.
// - Speed is the wall time of the whole transcription (voice detection and every decode, the audio read as fast as
//   the engine takes it) divided by the length of the audio. Under 1 keeps up with live audio; the limit is 0.8.
// - CPU is the process's CPU time over the same stretch, per second of audio: the share of one core the engine would
//   use when the same speech arrives live.

// MARK: - Limits

private enum Limit {
    /// Spec section 15: under 500 MB with the Balanced model. Light has to stay under it too.
    static let footprintMB = 500.0
    /// Spec section 8.5: the real-time guard warns above 0.8.
    static let realTimeRatio = 0.8
}

// MARK: - Gate and cache

/// The same folder as `WhisperEngineTests`, so the Light model and the speech detector are downloaded once for both.
private let cachedModelsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NameAlertTests/Models", isDirectory: true)

private let runsIntegration = ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1"

// MARK: - What is said

private enum Script {
    /// The name the engine is told to listen for.
    static let name = "Bala"

    /// Forty different sentences. Four of them have the name in them, the others are everyday talk (calls, news,
    /// recipes) with none of its near-sounds.
    static let sentences = [
        "Hey Bala, can you share your screen please?",
        "Bala, are you still there? We lost you for a second.",
        "Thanks Bala, that was really helpful before the break.",
        "Let's hear from Bala about the release schedule next.",
        "The weather is lovely today and the coffee is hot.",
        "Please open the quarterly report and look at the second chart.",
        "We should move the deadline to the end of next week.",
        "Could you mute your microphone while someone else is talking?",
        "I think the new design looks much cleaner than the old one.",
        "The train to the airport leaves every fifteen minutes.",
        "Remember to submit your expense forms before Friday afternoon.",
        "The server was restarted overnight and everything looks stable now.",
        "She walked to the market and bought fresh bread and tomatoes.",
        "Our customers keep asking for a simpler way to export their data.",
        "Let me know if you need anything else from the engineering team.",
        "The meeting will start in five minutes, so please find a seat.",
        "He said the package would arrive sometime on Tuesday morning.",
        "We reviewed the budget and agreed to hire two more designers.",
        "The documentary explains how glaciers shape the valleys around them.",
        "Can everyone see the slides, or should I make the text larger?",
        "Traffic was terrible this morning because of the road works.",
        "I'll send a summary of the decisions right after this call.",
        "The new library opens next month with a large children's section.",
        "Please double check the numbers before we share them with the board.",
        "Sorry, I was on mute again. Can you repeat the last question?",
        "The recipe calls for two cups of flour and a pinch of salt.",
        "Our flight was delayed by three hours, but we finally landed safely.",
        "Tomorrow's workshop covers testing strategies for large software projects.",
        "The museum has a wonderful collection of paintings from the nineteenth century.",
        "I would like to thank everyone who stayed late to finish the project.",
        "There is a small bug in the login screen that we should fix soon.",
        "The soccer match went into extra time and ended with a dramatic goal.",
        "Please remind me to call the dentist and book an appointment.",
        "Our team is planning a trip to the mountains in early spring.",
        "The latest update improves battery life and fixes several annoying crashes.",
        "Let's take a short break and come back at half past ten.",
        "The speaker explained how small habits can lead to big improvements.",
        "Could you forward the invitation to the rest of the department?",
        "It rained all weekend, so we stayed inside and watched old movies.",
        "The research shows that sleep matters more than most people think.",
    ]

    /// The silence after each sentence in turn, in seconds. Most are shorter than the 400 ms that ends a segment, so
    /// neighbouring sentences run together into segments of the full 6 s, the way people talk. The longer ones let
    /// segments end on a pause.
    static let pauses = [0.15, 0.35, 0.6, 0.25, 0.9, 0.2, 0.45]

    /// The length of the speech, in seconds.
    static let seconds = 600.0
}

private enum PerformanceError: Error, CustomStringConvertible {
    case sayFailed(status: Int32, sentence: String)
    case noSamples(sentence: String)

    var description: String {
        switch self {
        case .sayFailed(let status, let sentence): "`say` exited with status \(status) for \"\(sentence)\""
        case .noSamples(let sentence): "No audio came out of \"\(sentence)\""
        }
    }
}

/// `sentence` read by the system voice, as 16 kHz mono samples, with no silence added.
private func speak(_ sentence: String, to file: URL) throws -> [Float] {
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", file.path, sentence]
    try say.run()
    say.waitUntilExit()
    guard say.terminationStatus == 0 else {
        throw PerformanceError.sayFailed(status: say.terminationStatus, sentence: sentence)
    }

    let audio = try AVAudioFile(forReading: file)
    let capacity = AVAudioFrameCount(audio.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity) else {
        throw PerformanceError.noSamples(sentence: sentence)
    }
    try audio.read(into: buffer)
    // A new converter for every clip, so none of the resampler's state carries over from the one before.
    let samples = AudioFormatConverter().convert(buffer)
    guard !samples.isEmpty else { throw PerformanceError.noSamples(sentence: sentence) }
    return samples
}

/// About ten minutes of speech: the forty sentences read once, then played in a fixed scrambled order, each followed by
/// a pause, until the time is up.
private struct TenMinutesOfSpeech: Sendable {
    let samples: [Float]
    /// How many sentences were played, how many of them have the name, and how many words they hold in all.
    let sentenceCount: Int
    let nameCount: Int
    let wordCount: Int

    var seconds: Double { Double(samples.count) / AudioChunk.sampleRate }

    static func build() throws -> TenMinutesOfSpeech {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Each sentence is read once...
        var clips: [[Float]] = []
        for (number, sentence) in Script.sentences.enumerated() {
            clips.append(try speak(sentence, to: folder.appendingPathComponent("sentence-\(number).aiff")))
        }

        // ...and played again and again. 7 and 40 have no common factor, so every round of forty turns plays every
        // sentence once, in an order that is the same on every run.
        var samples: [Float] = []
        var sentenceCount = 0
        var nameCount = 0
        var wordCount = 0
        let target = Int(Script.seconds * AudioChunk.sampleRate)
        while samples.count < target {
            let index = (sentenceCount * 7 + 3) % clips.count
            let words = TextNormalizer.tokens(Script.sentences[index])
            samples += clips[index]
            let pause = Script.pauses[sentenceCount % Script.pauses.count]
            samples += [Float](repeating: 0, count: Int(pause * AudioChunk.sampleRate))
            sentenceCount += 1
            wordCount += words.count
            if words.contains(Script.name.lowercased()) { nameCount += 1 }
        }
        // A second of quiet at the end, the way the other whisper tests end their audio.
        samples += [Float](repeating: 0, count: Int(AudioChunk.sampleRate))
        return TenMinutesOfSpeech(
            samples: samples, sentenceCount: sentenceCount, nameCount: nameCount, wordCount: wordCount)
    }

    /// The samples as numbered 100 ms chunks, handed out one at a time as the engine asks for them, so the test does
    /// not hold a second copy of ten minutes of audio in chunks. The last chunk is padded with silence.
    func stream() -> AsyncStream<AudioChunk> {
        let samples = samples
        let next = OSAllocatedUnfairLock(initialState: 0)
        return AsyncStream(unfolding: {
            let number = next.withLock { value -> Int in
                defer { value += 1 }
                return value
            }
            let size = AudioChunk.samplesPerChunk
            let start = number * size
            guard start < samples.count else { return nil }
            var piece = Array(samples[start..<min(start + size, samples.count)])
            piece += [Float](repeating: 0, count: size - piece.count)
            return AudioChunk(samples: piece, sequence: UInt64(number))
        })
    }
}

/// Built once for both models: reading forty sentences takes a while.
private let sharedSpeech = Result { try TenMinutesOfSpeech.build() }

// MARK: - Measuring

private enum Memory {
    static let megabyte = 1_048_576.0

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info : nil
    }

    /// What this process uses now, in megabytes: its physical footprint.
    static func footprintMB() -> Double { Double(vmInfo()?.phys_footprint ?? 0) / megabyte }

    /// The most the footprint has been since the process started, in megabytes. The kernel keeps this one, so a spike
    /// between two samples is in it. It also holds whatever the process did before the test, so it is only reported.
    static func lifetimePeakMB() -> Double { Double(vmInfo()?.ledger_phys_footprint_peak ?? 0) / megabyte }
}

/// Reads the footprint every 50 ms, on its own timer, until `stop`, and remembers the largest value.
private final class PeakFootprint: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.balakumar.namealert.tests.footprint", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var peakMB = 0.0  // only touched on `queue`

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [self] in peakMB = max(peakMB, Memory.footprintMB()) }
        self.timer = timer
        timer.resume()
    }

    /// Stops sampling and returns the largest footprint seen, in megabytes.
    func stop() -> Double {
        queue.sync {
            timer?.cancel()
            timer = nil
            peakMB = max(peakMB, Memory.footprintMB())
            return peakMB
        }
    }
}

/// The CPU time this process has used so far, in seconds, over all of its threads.
private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func format(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

// MARK: - Tests

@Suite(
    "WhisperPerformance", .serialized,
    .enabled(if: runsIntegration, "Set NAMEALERT_INTEGRATION=1 to download the models and run ten minutes of speech."))
struct WhisperPerformanceTests {
    /// Light, then Balanced, one after the other in this process (the suite is serialized, so they never overlap).
    @Test(
        "Ten minutes of speech stay under the memory limit and keep up with live audio",
        .timeLimit(.minutes(20)),
        arguments: [LocalModelSize.light, LocalModelSize.balanced])
    func tenMinutesOfSpeech(size: LocalModelSize) async throws {
        let label = size == .light ? "Light" : "Balanced"
        let speech = try sharedSpeech.get()

        let models = ModelManager(directory: cachedModelsDirectory)
        try await models.download(ModelCatalog.model(size: size, localeIdentifier: "en-US")) { _ in }
        try await models.download(.vad) { _ in }

        let fellBehind = OSAllocatedUnfairLock(initialState: 0)
        let engine = WhisperEngine(
            size: size, modelManager: models, onFallingBehind: { fellBehind.withLock { $0 += 1 } })

        let beforeMB = Memory.footprintMB()
        let sampler = PeakFootprint()
        defer { _ = sampler.stop() }  // when a step below throws; stopping twice is fine
        let cpuAtStart = processCPUSeconds()
        let clock = ContinuousClock()

        let loadStarted = clock.now
        try await engine.prepare(localeIdentifier: "en-US", hints: [Script.name], progress: { _ in })
        let loadSeconds = seconds(clock.now - loadStarted)

        let cpuBeforeTranscribing = processCPUSeconds()
        let started = clock.now
        var updates: [TranscriptUpdate] = []
        do {
            for try await update in engine.transcribe(speech.stream()) {
                updates.append(update)
            }
        } catch {
            await engine.stop()  // so that the next model does not start with this one's memory
            throw error
        }
        let processingSeconds = seconds(clock.now - started)
        let cpuSeconds = processCPUSeconds() - cpuBeforeTranscribing
        await engine.stop()
        let peakMB = sampler.stop()

        let audioSeconds = speech.seconds
        let ratio = processingSeconds / audioSeconds
        let heardWords = updates.flatMap { TextNormalizer.tokens($0.text) }
        let term = Script.name.lowercased()
        let nameHeard = heardWords.filter { Sensitivity.balanced.matches(term: term, heard: $0) }.count

        let lifetimePeakMB = Memory.lifetimePeakMB()
        print(
            "[whisper-perf] \(label): \(format(audioSeconds)) s of speech processed in \(format(processingSeconds)) s, "
                + "ratio \(format(ratio, 3)) (limit \(Limit.realTimeRatio)); "
                + "peak memory \(format(peakMB)) MB (limit \(format(Limit.footprintMB, 0)) MB; "
                + "\(format(beforeMB)) MB before the engine, process peak so far \(format(lifetimePeakMB)) MB); "
                + "CPU \(format(100 * cpuSeconds / audioSeconds))% of one core when the speech arrives live"
        )
        print(
            "[whisper-perf] \(label): \(speech.sentenceCount) sentences, \(speech.wordCount) words; "
                + "heard \(heardWords.count) words in \(updates.count) segments; "
                + "\"\(Script.name)\" said \(speech.nameCount) times, heard \(nameHeard) times; "
                + "model load \(format(loadSeconds, 2)) s "
                + "(CPU \(format(cpuBeforeTranscribing - cpuAtStart, 2)) s); "
                + "falling-behind warnings \(fellBehind.withLock { $0 })"
        )

        #expect(peakMB < Limit.footprintMB, "\(label) used \(format(peakMB)) MB at its peak")
        #expect(ratio < Limit.realTimeRatio, "\(label) took \(format(ratio, 3)) s per second of audio")
        #expect(fellBehind.withLock { $0 } == 0, "\(label) told the app it could not keep up")
        // Without these the numbers above could come from an engine that heard nothing.
        #expect(!updates.isEmpty, "\(label) heard no speech")
        #expect(nameHeard >= 1, "\(label) never heard \"\(Script.name)\" in \(speech.nameCount) mentions")
    }
}
