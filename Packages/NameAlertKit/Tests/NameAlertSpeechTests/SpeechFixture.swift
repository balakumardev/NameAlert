import AVFoundation
import Foundation
import NameAlertAudio
import NameAlertCore
import Testing

/// Spoken test audio made with the system voice, delivered the way a capture source delivers it (the same recipe as
/// the whisper tests: `say`, then `AudioFormatConverter`, then 100 ms chunks).
enum SpeechFixture {
    /// `sentence` read by the system voice, as 16 kHz mono samples, followed by a second of silence.
    static func spokenSamples(_ sentence: String) throws -> [Float] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlertSpeech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
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

    /// The samples as numbered 100 ms chunks. The last one is padded with silence.
    static func chunks(of samples: [Float]) -> [AudioChunk] {
        let size = AudioChunk.samplesPerChunk
        return stride(from: 0, to: samples.count, by: size).enumerated().map { number, start in
            var piece = Array(samples[start..<min(start + size, samples.count)])
            piece += [Float](repeating: 0, count: size - piece.count)
            return AudioChunk(samples: piece, sequence: UInt64(number))
        }
    }

    /// A stream that holds all the chunks of `samples` and then ends.
    static func stream(of samples: [Float]) -> AsyncStream<AudioChunk> {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        for chunk in chunks(of: samples) { input.yield(chunk) }
        input.finish()
        return audio
    }

    /// The words of `updates`' final texts, normalized the way the matcher sees them.
    static func finalWords(_ updates: [TranscriptUpdate]) -> [String] {
        updates.filter(\.isFinal).flatMap { TextNormalizer.tokens($0.text) }
    }

    /// A one-line summary of `updates` for the test log: each update's segment, whether it is final, and its text.
    static func describe(_ updates: [TranscriptUpdate]) -> String {
        updates.map { "\($0.segmentID)\($0.isFinal ? " final" : "") \"\($0.text)\" \($0.alternatives)" }
            .joined(separator: " | ")
    }
}
