import AVFoundation
import NameAlertAudio
import NameAlertCore
import Testing

// MARK: - Helpers

/// A Float32 buffer holding a `frequency` Hz sine wave in every channel, or only in `activeChannels`.
///
/// `firstFrame` continues the wave where an earlier buffer ended, so consecutive buffers form one signal.
/// A `layout` makes the format carry that channel layout (needed for more than two channels).
private func makeSineBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    frames: Int,
    firstFrame: Int = 0,
    frequency: Double = 440,
    amplitude: Float = 0.8,
    activeChannels: Set<Int>? = nil,
    layout: AVAudioChannelLayout? = nil
) throws -> AVAudioPCMBuffer {
    let format: AVAudioFormat
    if let layout {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    } else {
        format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for channel in 0 ..< Int(format.channelCount) {
        let isActive = activeChannels?.contains(channel) ?? true
        for frame in 0 ..< frames {
            let phase = 2 * Double.pi * frequency * Double(firstFrame + frame) / sampleRate
            data[channel][frame] = isActive ? amplitude * Float(sin(phase)) : 0
        }
    }
    return buffer
}

/// A 16-bit interleaved buffer (the layout of a typical USB device) with a sine wave in every channel.
private func makeInt16InterleavedBuffer(
    sampleRate: Double, channels: AVAudioChannelCount, frames: Int, amplitude: Float = 0.8
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.int16ChannelData)
    for frame in 0 ..< frames {
        let value = amplitude * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        for channel in 0 ..< Int(channels) {
            data[0][frame * Int(channels) + channel] = Int16(value * 32_767)
        }
    }
    return buffer
}

private func peak(_ samples: [Float]) -> Float {
    samples.map(abs).max() ?? 0
}

/// The largest jump between two neighbouring samples. A 440 Hz sine of amplitude 0.8 at 16 kHz never moves by more
/// than about 0.14, so a bigger step means the signal was cut or restarted.
private func largestStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

private func constant(_ value: Float, count: Int) -> [Float] {
    [Float](repeating: value, count: count)
}

/// Whether every sample of `chunk` is `value` (within float rounding) and the chunk has the expected length.
private func isConstant(_ chunk: [Float], _ value: Float, count: Int = AudioChunk.samplesPerChunk) -> Bool {
    chunk.count == count && chunk.allSatisfy { abs($0 - value) < 1e-6 }
}

/// `count` samples of `scale × index`: a signal whose every sample is distinguishable from its neighbours.
private func ramp(count: Int, scale: Float) -> [Float] {
    (0 ..< count).map { Float($0) * scale }
}

private func matches(_ samples: [Float], _ expected: [Float], tolerance: Float = 1e-6) -> Bool {
    samples.count == expected.count && zip(samples, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

// MARK: - Tests

@Suite("AudioProcessing")
struct AudioProcessingTests {
    private let chunk = AudioChunk.samplesPerChunk

    // MARK: AudioFormatConverter

    @Test func converts48kStereo() throws {
        let converter = AudioFormatConverter()
        let samples = converter.convert(try makeSineBuffer(sampleRate: 48_000, channels: 2, frames: 48_000))
        #expect(abs(samples.count - 16_000) <= 160, "got \(samples.count) samples")
        #expect(peak(samples) > 0.5)
    }

    @Test func passthrough16kMono() throws {
        let converter = AudioFormatConverter()
        let input = try makeSineBuffer(sampleRate: 16_000, channels: 1, frames: 1_000)
        let samples = converter.convert(input)
        let expected = Array(UnsafeBufferPointer(start: try #require(input.floatChannelData)[0], count: 1_000))
        #expect(samples.count == 1_000)
        #expect(matches(samples, expected, tolerance: 1e-4))
    }

    @Test func converts44k1Mono() throws {
        let converter = AudioFormatConverter()
        let samples = converter.convert(try makeSineBuffer(sampleRate: 44_100, channels: 1, frames: 44_100))
        #expect(abs(samples.count - 16_000) <= 160, "got \(samples.count) samples")
        #expect(peak(samples) > 0.5)
    }

    /// The converter's own default keeps only the first channel and would lose a voice that sits on the right.
    @Test func bothStereoChannelsReachTheOutput() throws {
        let converter = AudioFormatConverter()
        for active in [0, 1] {
            let input = try makeSineBuffer(sampleRate: 48_000, channels: 2, frames: 48_000, activeChannels: [active])
            let samples = converter.convert(input)
            #expect(peak(samples) > 0.3, "channel \(active) alone gave a peak of \(peak(samples))")
        }
    }

    /// A multi-channel audio interface reports a "discrete" channel layout, which the platform converter turns into
    /// silence when asked to down-mix. The microphone could be on any input, so any one of them must be heard.
    @Test func multiChannelInterfaceIsNotSilent() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let converter = AudioFormatConverter()
        for active in 0 ..< 4 {
            let input = try makeSineBuffer(
                sampleRate: 48_000, channels: 4, frames: 24_000, activeChannels: [active], layout: layout)
            let samples = converter.convert(input)
            #expect(abs(samples.count - 8_000) <= 80, "got \(samples.count) samples")
            #expect(peak(samples) > 0.1, "input \(active + 1) alone gave a peak of \(peak(samples))")
        }
    }

    @Test func convertsAnyPCMFormat() throws {
        let converter = AudioFormatConverter()
        let samples = converter.convert(try makeInt16InterleavedBuffer(sampleRate: 44_100, channels: 2, frames: 44_100))
        #expect(abs(samples.count - 16_000) <= 160, "got \(samples.count) samples")
        #expect(abs(peak(samples) - 0.8) < 0.05, "peak \(peak(samples))")
    }

    @Test func rebuildsTheConverterWhenTheInputFormatChanges() throws {
        let converter = AudioFormatConverter()
        // Includes 16 kHz mono (no conversion) between two converted formats, and a return to an earlier format.
        let formats: [(rate: Double, channels: AVAudioChannelCount)] =
            [(48_000, 2), (44_100, 1), (16_000, 1), (48_000, 1), (48_000, 2), (22_050, 1)]
        for (rate, channels) in formats {
            let samples = converter.convert(
                try makeSineBuffer(sampleRate: rate, channels: channels, frames: Int(rate)))
            #expect(abs(samples.count - 16_000) <= 160, "\(rate) Hz x\(channels) gave \(samples.count) samples")
            #expect(peak(samples) > 0.5, "\(rate) Hz x\(channels) gave a peak of \(peak(samples))")
        }
    }

    /// Real capture delivers many buffers of 5 ms to 400 ms. None of them may lose samples or leave a click at the seam.
    @Test func streamedBuffersKeepEverySample() throws {
        let cases: [(frames: Int, channels: AVAudioChannelCount)] = [(480, 2), (4_096, 1), (4_800, 2), (19_200, 2)]
        for (frames, channels) in cases {
            let converter = AudioFormatConverter()
            let bufferCount = 240_000 / frames // five seconds at 48 kHz
            var samples: [Float] = []
            for index in 0 ..< bufferCount {
                samples += converter.convert(try makeSineBuffer(
                    sampleRate: 48_000, channels: channels, frames: frames, firstFrame: index * frames))
            }
            let expected = Double(bufferCount * frames) / 3
            #expect(
                abs(Double(samples.count) - expected) <= expected * 0.001,
                "\(frames) frames x\(channels): got \(samples.count) of \(expected) samples")
            #expect(
                largestStep(samples) < 0.2,
                "\(frames) frames x\(channels): the signal jumps by \(largestStep(samples))")
        }
    }

    @Test func emptyBufferGivesNoSamples() throws {
        let converter = AudioFormatConverter()
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        #expect(empty.frameLength == 0)
        #expect(converter.convert(empty).isEmpty)
        // And it does not disturb the next real buffer.
        let samples = converter.convert(try makeSineBuffer(sampleRate: 48_000, channels: 2, frames: 48_000))
        #expect(abs(samples.count - 16_000) <= 160)
    }

    @Test func concurrentCallsShareOneConverter() async {
        let converter = AudioFormatConverter()
        let tasks = 4
        let buffersPerTask = 25
        let frames = 4_096
        let total = await withTaskGroup(of: Int.self) { group in
            for task in 0 ..< tasks {
                group.addTask {
                    var count = 0
                    for index in 0 ..< buffersPerTask {
                        guard let buffer = try? makeSineBuffer(
                            sampleRate: 48_000, channels: 2, frames: frames,
                            firstFrame: (task * buffersPerTask + index) * frames)
                        else { return -1_000_000 }
                        count += converter.convert(buffer).count
                    }
                    return count
                }
            }
            var sum = 0
            for await count in group { sum += count }
            return sum
        }
        // Every call is serialized, so nothing is lost or counted twice however the calls interleave.
        let expected = Double(tasks * buffersPerTask * frames) / 3
        #expect(abs(Double(total) - expected) <= expected * 0.01, "got \(total) of \(expected) samples")
    }

    // MARK: ChunkAssembler

    @Test func assemblerSplits() {
        var assembler = ChunkAssembler()
        let signal = ramp(count: 3_200, scale: 0.0001)
        #expect(assembler.push(Array(signal[0 ..< 1_000])).isEmpty)

        let first = assembler.push(Array(signal[1_000 ..< 2_000]))
        #expect(first.count == 1)
        #expect(first.first.map { matches($0, Array(signal[0 ..< chunk])) } == true)

        let second = assembler.push(Array(signal[2_000 ..< 3_200]))
        #expect(second.count == 1)
        #expect(second.first.map { matches($0, Array(signal[chunk ..< 2 * chunk])) } == true)
    }

    @Test func assemblerEmitsEveryCompleteChunkAndKeepsTheRest() {
        var assembler = ChunkAssembler()
        let signal = ramp(count: 4_800, scale: 0.0001)
        let chunks = assembler.push(Array(signal[0 ..< 4_000])) // two whole chunks, 800 left over
        #expect(chunks.count == 2)
        #expect(chunks.first.map { matches($0, Array(signal[0 ..< chunk])) } == true)
        #expect(chunks.last.map { matches($0, Array(signal[chunk ..< 2 * chunk])) } == true)

        let rest = assembler.push(Array(signal[4_000 ..< 4_800])) // the 800 kept plus 800 new
        #expect(rest.count == 1)
        #expect(rest.first.map { matches($0, Array(signal[2 * chunk ..< 3 * chunk])) } == true)
        #expect(assembler.push([]).isEmpty)
    }

    @Test func assemblerHonorsACustomChunkSize() {
        var assembler = ChunkAssembler(chunkSamples: 4)
        #expect(assembler.push([1, 2, 3]).isEmpty)
        #expect(assembler.push([4, 5, 6, 7, 8, 9]) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        #expect(assembler.push([10, 11, 12]) == [[9, 10, 11, 12]])
    }

    // MARK: AudioMixer

    @Test func mixerSums() {
        var mixer = AudioMixer()
        #expect(mixer.push(constant(0.5, count: chunk), from: .first).isEmpty)
        let chunks = mixer.push(constant(0.25, count: chunk), from: .second)
        #expect(chunks.count == 1)
        #expect(chunks.first.map { isConstant($0, 0.75) } == true)
    }

    @Test func mixerClamps() {
        var mixer = AudioMixer()
        _ = mixer.push(constant(0.8, count: chunk), from: .first)
        let positive = mixer.push(constant(0.8, count: chunk), from: .second)
        #expect(positive.count == 1)
        #expect(positive.first.map { isConstant($0, 1.0) } == true)

        _ = mixer.push(constant(-0.8, count: chunk), from: .first)
        let negative = mixer.push(constant(-0.8, count: chunk), from: .second)
        #expect(negative.count == 1)
        #expect(negative.first.map { isConstant($0, -1.0) } == true)
    }

    @Test func mixerStarvation() {
        var mixer = AudioMixer()
        let chunks = mixer.push(constant(0.3, count: 4_800), from: .first)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { isConstant($0, 0.3) })
    }

    @Test func mixerWaitsBelowStarvation() {
        var mixer = AudioMixer()
        #expect(mixer.push(constant(0.3, count: 3_200), from: .first).isEmpty)
    }

    @Test func mixerPassesEitherInputThroughWhenTheOtherIsStarved() {
        var mixer = AudioMixer()
        let chunks = mixer.push(constant(0.2, count: 4_800), from: .second)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { isConstant($0, 0.2) })
    }

    @Test func mixerWaitsForAnInputThatIsOnlySlow() {
        var mixer = AudioMixer()
        // 4 700 samples is just under 300 ms: the second input may still be about to deliver.
        #expect(mixer.push(constant(0.3, count: 4_700), from: .first).isEmpty)
        let chunks = mixer.push(constant(0.1, count: chunk), from: .second)
        #expect(chunks.count == 1)
        #expect(chunks.first.map { isConstant($0, 0.4) } == true)
    }

    @Test func mixerKeepsEachInputInOrderAndKeepsLeftovers() {
        var mixer = AudioMixer()
        let first = ramp(count: 3_200, scale: 0.0001)
        let second = ramp(count: 3_200, scale: 0.0002)
        func expectedChunk(_ index: Int) -> [Float] {
            zip(first[index * chunk ..< (index + 1) * chunk], second[index * chunk ..< (index + 1) * chunk]).map { $0 + $1 }
        }

        #expect(mixer.push(Array(first[0 ..< 1_000]), from: .first).isEmpty)
        #expect(mixer.push(Array(first[1_000 ..< 2_000]), from: .first).isEmpty)
        let one = mixer.push(Array(second[0 ..< chunk]), from: .second)
        #expect(one.count == 1)
        #expect(one.first.map { matches($0, expectedChunk(0)) } == true)

        // 400 samples of the first input are left over from that chunk, so the next one still needs 1 200 more.
        #expect(mixer.push(Array(second[chunk ..< 3_200]), from: .second).isEmpty)
        let two = mixer.push(Array(first[2_000 ..< 3_200]), from: .first)
        #expect(two.count == 1)
        #expect(two.first.map { matches($0, expectedChunk(1)) } == true)
    }

    @Test func mixerEmitsSeveralChunksFromOnePushAndKeepsTheRest() {
        var mixer = AudioMixer()
        #expect(mixer.push(constant(0.1, count: 2 * chunk), from: .first).isEmpty)
        let chunks = mixer.push(constant(0.2, count: 3 * chunk), from: .second) // two whole chunks, one left over
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { isConstant($0, 0.3) })

        let late = mixer.push(constant(0.1, count: chunk), from: .first) // pairs with the chunk that was kept
        #expect(late.count == 1)
        #expect(late.first.map { isConstant($0, 0.3) } == true)
    }
}
