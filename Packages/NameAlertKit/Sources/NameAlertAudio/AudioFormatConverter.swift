import AVFoundation
import Foundation
import NameAlertCore

/// Turns the buffers a capture device or ScreenCaptureKit delivers into 16 kHz mono Float32 samples, the format the
/// rest of the app works in.
///
/// Any PCM format is accepted (other sample rates, Int16, interleaved, several channels). Several channels are
/// averaged into one, but only those that are about as loud as the loudest (see `average`), so that a microphone on
/// one input of a multi-channel interface is not diluted by the inputs with nothing on them. A buffer that is
/// already 16 kHz mono Float32 passes straight through.
///
/// One `AVAudioConverter` is kept for the current input format and replaced when the format changes, for example
/// when the user switches the output device. Keeping it between buffers keeps the resampler's history, so there is
/// no click where one buffer ends and the next begins.
///
/// Calls from different threads are serialized by a lock. If a buffer cannot be converted, the call returns no
/// samples and the failure is logged once per input format, so a broken device cannot flood the log.
public final class AudioFormatConverter: @unchecked Sendable {
    /// The most frames handed to the converter at once. It asks for 4 096 at a time. Handing it more in one go makes
    /// it discard part of the excess for input with more than one channel (measured: one 1 s stereo buffer came back
    /// 6 % short, and over two such buffers about 600 samples were lost for good), and a microphone tap may
    /// deliver buffers of 100 to 400 ms.
    private static let sliceFrames = 4_096

    /// How far below the loudest channel a channel may be, by RMS, and still be averaged in: 12 dB, as an amplitude
    /// ratio.
    private static let activeChannelWindow = Float(pow(10.0, -12.0 / 20.0))

    private static let log = Log.logger("audio")

    private let lock = NSLock()
    /// Both guarded by `lock`.
    private var pipeline: Pipeline?
    private var failureLoggedFor: FormatKey?

    public init() {}

    /// Returns `buffer` as 16 kHz mono Float32 samples. The count is the buffer's duration at 16 kHz, give or take a
    /// few samples that the resampler keeps for the next call.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        return lock.withLock { convertLocked(buffer) }
    }

    // MARK: Conversion

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        if Self.isTargetFormat(format) {
            // Forget the converter, so coming back to a converted format later starts a clean stream.
            pipeline = nil
            return Self.monoSamples(of: buffer)
        }

        let key = FormatKey(format)
        if pipeline?.key != key {
            pipeline = Self.makePipeline(for: format, key: key)
        }
        guard let pipeline else { return fail(key, "no converter for this format") }

        let frames = Int(buffer.frameLength)
        let capacity = Self.outputCapacity(frames: frames, inputRate: format.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: pipeline.outputFormat, frameCapacity: capacity) else {
            return fail(key, "no memory for the output buffer")
        }

        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let slice = UnsafeMutableAudioBufferListPointer(pipeline.slice.mutableAudioBufferList)
        let bytesPerFrame = Int(key.bytesPerFrame)
        var consumed = 0
        var conversionError: NSError?
        // The converter pulls input through this block, asking for a number of frames each time. Answering with at
        // most that number, and never more than a slice, is what keeps it from discarding input (see `sliceFrames`).
        // `.noDataNow`, not `.endOfStream`, once the buffer is used up: the converter keeps its state for the next call.
        let status = pipeline.converter.convert(to: output, error: &conversionError) { requested, inputStatus in
            let count = min(Int(max(requested, 1)), frames - consumed, Self.sliceFrames)
            guard count > 0,
                  Self.copyFrames(from: source, offset: consumed, count: count, bytesPerFrame: bytesPerFrame, to: slice)
            else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pipeline.slice.frameLength = AVAudioFrameCount(count)
            consumed += count
            inputStatus.pointee = .haveData
            return pipeline.slice
        }
        guard status != .error else {
            return fail(key, conversionError?.localizedDescription ?? "the conversion reported an error")
        }

        // A short first buffer can legitimately produce nothing while the resampler primes itself.
        let producedFrames = Int(output.frameLength)
        guard producedFrames > 0, let channels = output.floatChannelData else { return [] }
        let channelCount = Int(pipeline.outputFormat.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: producedFrames))
        }
        return Self.average(channels, channelCount: channelCount, frames: producedFrames)
    }

    /// Records a failure and returns no samples. Logs the first failure for each input format and no more.
    private func fail(_ key: FormatKey, _ reason: String) -> [Float] {
        if failureLoggedFor != key {
            failureLoggedFor = key
            Self.log.error(
                "Audio conversion failed (\(key.sampleRate, privacy: .public) Hz, \(key.channelCount, privacy: .public) channels): \(reason, privacy: .public)")
        }
        return []
    }

    // MARK: Pipeline

    /// What decides whether the converter in use still fits a buffer: the sample layout in memory. The channel layout
    /// that a format also carries is left out on purpose, because every channel is treated the same.
    private struct FormatKey: Equatable {
        let sampleRate: Double
        let channelCount: UInt32
        let formatFlags: AudioFormatFlags
        let bitsPerChannel: UInt32
        let bytesPerFrame: UInt32

        init(_ format: AVAudioFormat) {
            let description = format.streamDescription.pointee
            sampleRate = description.mSampleRate
            channelCount = description.mChannelsPerFrame
            formatFlags = description.mFormatFlags
            bitsPerChannel = description.mBitsPerChannel
            bytesPerFrame = description.mBytesPerFrame
        }
    }

    /// Everything that depends on the input format.
    private struct Pipeline {
        let key: FormatKey
        let converter: AVAudioConverter
        /// 16 kHz Float32 with one channel per input channel. The channels are averaged after conversion.
        let outputFormat: AVAudioFormat
        /// Holds the slice currently handed to the converter. It is reused: the converter is done with a slice by the
        /// time it asks for the next one.
        let slice: AVAudioPCMBuffer
    }

    private static func makePipeline(for format: AVAudioFormat, key: FormatKey) -> Pipeline? {
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { return nil }

        let outputFormat: AVAudioFormat
        if channels == 1 {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false)
            else { return nil }
            outputFormat = mono
        } else {
            guard let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
            else { return nil }
            outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, interleaved: false,
                channelLayout: layout)
        }

        guard let converter = AVAudioConverter(from: format, to: outputFormat),
              let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sliceFrames))
        else { return nil }

        // Input channel i becomes output channel i. Left to itself the converter picks channels by their labels,
        // which keeps only the first channel of a stereo stream (a voice on the right is lost). Even with its
        // `downmix` switch on, input with a "discrete" channel layout, which is how more than two unlabeled
        // channels (a multi-channel audio interface) are described, comes out as silence. Resampling every channel
        // and averaging them here has neither problem.
        converter.channelMap = (0 ..< channels).map { NSNumber(value: $0) }
        return Pipeline(key: key, converter: converter, outputFormat: outputFormat, slice: slice)
    }

    // MARK: Helpers

    /// 16 kHz mono Float32 in one plane: nothing to convert.
    private static func isTargetFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && format.sampleRate == AudioChunk.sampleRate
            && format.channelCount == 1 && !format.isInterleaved
    }

    /// The samples of a buffer that is already 16 kHz mono Float32.
    private static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }

    /// `ceil(frames × 16 000 / inputRate) + 1 024`: all that `frames` input frames can produce, with room to spare.
    private static func outputCapacity(frames: Int, inputRate: Double) -> AVAudioFrameCount {
        let estimate = (Double(frames) * AudioChunk.sampleRate / inputRate).rounded(.up) + 1_024
        return AVAudioFrameCount(min(estimate, Double(AVAudioFrameCount.max)))
    }

    /// Copies `count` frames, starting at frame `offset`, from `source` into `target` (same format, so the same
    /// buffer count and bytes per frame). Returns false if either side has no memory behind it.
    private static func copyFrames(
        from source: UnsafeMutableAudioBufferListPointer, offset: Int, count: Int, bytesPerFrame: Int,
        to target: UnsafeMutableAudioBufferListPointer
    ) -> Bool {
        guard source.count == target.count else { return false }
        for index in 0 ..< source.count {
            guard let from = source[index].mData, let to = target[index].mData else { return false }
            memcpy(to, from + offset * bytesPerFrame, count * bytesPerFrame)
        }
        return true
    }

    /// The mean, sample by sample, of the channels that are about as loud as the loudest one.
    ///
    /// Averaging every channel would divide a microphone that sits on one input of a multi-channel interface by the
    /// number of inputs (a voice 12 dB down with four of them), because the other inputs carry nothing or only hiss.
    /// So the RMS of each channel is measured over this buffer, and a channel more than 12 dB below the loudest one is
    /// left out. Channels that are about as loud, such as the two sides of a stereo pair or one voice that several
    /// inputs pick up, are averaged as before. When every channel is silent there is no loudest one to measure
    /// against, and the result is silence.
    private static func average(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int
    ) -> [Float] {
        var rms = [Float](repeating: 0, count: channelCount)
        for channel in 0 ..< channelCount {
            let samples = channels[channel]
            var energy: Float = 0
            for frame in 0 ..< frames {
                energy += samples[frame] * samples[frame]
            }
            rms[channel] = (energy / Float(frames)).squareRoot()
        }
        var mixed = [Float](repeating: 0, count: frames)
        guard let loudest = rms.max(), loudest > 0 else { return mixed }

        // The loudest channel always passes, so at least one is averaged.
        let threshold = loudest * activeChannelWindow
        var averaged = 0
        for channel in 0 ..< channelCount where rms[channel] >= threshold {
            let samples = channels[channel]
            for frame in 0 ..< frames {
                mixed[frame] += samples[frame]
            }
            averaged += 1
        }
        let scale = 1 / Float(averaged)
        for frame in 0 ..< frames {
            mixed[frame] *= scale
        }
        return mixed
    }
}
