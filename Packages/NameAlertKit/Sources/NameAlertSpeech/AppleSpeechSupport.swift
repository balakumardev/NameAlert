import AVFoundation
import Foundation
import NameAlertCore

/// The app's audio (16 kHz mono Float32 samples) as the `AVAudioPCMBuffer`s that Apple's recognizers take.
enum MonoAudio {
    /// 16 kHz mono in the standard format: Float32, one plane per channel.
    static func makeFormat() -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: AudioChunk.sampleRate, channels: 1)
    }

    /// A buffer that holds `samples`, in `format`, which must be the one `makeFormat()` makes. Nil when there are no
    /// samples or no memory.
    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            if let start = source.baseAddress { channel.update(from: start, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Tidies what an Apple recognizer heard before it is reported.
enum Readings {
    /// How many other readings an update carries at most.
    static let maxAlternatives = 3

    /// The text without the spaces and line breaks around it. (`SpeechAnalyzer` starts a result with the space that
    /// separates it from the one before.)
    static func text(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to `limit` of the other readings, best first, tidied: none that is empty, a repeat, or the text itself.
    static func alternatives(_ candidates: [String], besides text: String, limit: Int = maxAlternatives) -> [String] {
        var seen: Set<String> = [text]
        var picked: [String] = []
        for candidate in candidates where picked.count < limit {
            let reading = Self.text(candidate)
            guard !reading.isEmpty, seen.insert(reading).inserted else { continue }
            picked.append(reading)
        }
        return picked
    }
}
