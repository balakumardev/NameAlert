import Foundation
import NameAlertSpeech
import Testing

// MARK: - Helpers

private let frameSize = VADSegmenter.frameSamples
private let silentFrame = [Float](repeating: 0, count: frameSize)

/// `count` frames in a row that the detector gave the speech probability `p`.
private typealias Run = (count: Int, p: Float)

/// Pushes the runs through a segmenter one frame at a time and returns everything it handed out.
///
/// Frames are zeros. With `tagFrames` each frame is filled with its own number instead, so a test can see which
/// audio ended up in which segment.
private func segments(
    from runs: [Run], using segmenter: VADSegmenter = VADSegmenter(), tagFrames: Bool = false, flush: Bool = false
) -> [SpeechSegment] {
    var segmenter = segmenter
    var found: [SpeechSegment] = []
    var number = 0
    for (count, p) in runs {
        for _ in 0..<count {
            let frame = tagFrames ? [Float](repeating: Float(number), count: frameSize) : silentFrame
            found += segmenter.push(frame: frame, probability: p)
            number += 1
        }
    }
    if flush { found += segmenter.flush() }
    return found
}

/// The samples of the tagged frames `numbers`, one after the other.
private func taggedAudio(_ numbers: Range<Int>) -> [Float] {
    numbers.flatMap { [Float](repeating: Float($0), count: frameSize) }
}

/// Where the frames numbered `numbers` begin, in samples.
private func startSamples(ofFrames numbers: [Int]) -> [Int64] {
    numbers.map { Int64($0 * frameSize) }
}

/// How many samples that many frames hold, for each count in `frames`.
private func sampleCounts(ofFrames frames: [Int]) -> [Int] {
    frames.map { $0 * frameSize }
}

/// Samples of +level and -level in turn: no offset, and an RMS of exactly `level`.
private func noiseFrame(rms level: Float) -> [Float] {
    (0..<frameSize).map { $0.isMultiple(of: 2) ? level : -level }
}

/// A 500 Hz sine with the given peak. A frame holds 16 whole cycles of it.
private func toneFrame(peak: Float) -> [Float] {
    (0..<frameSize).map { peak * Float(sin(2 * Double.pi * 16 * Double($0) / Double(frameSize))) }
}

/// The RMS at a level in dBFS (0 dBFS is full scale).
private func rms(dBFS: Double) -> Float {
    Float(pow(10, dBFS / 20))
}

/// The peak a sine needs to have an RMS at `rmsDBFS`.
private func peak(rmsDBFS: Double) -> Float {
    rms(dBFS: rmsDBFS) * Float(2).squareRoot()
}

/// The probabilities `vad` gives for `count` copies of `frame`.
private func probabilities(_ vad: inout EnergyVAD, for frame: [Float], count: Int) -> [Float] {
    var found: [Float] = []
    for _ in 0..<count { found.append(vad.probability(for: frame)) }
    return found
}

// MARK: - Tests

@Suite("Segmentation")
struct SegmentationTests {
    // MARK: The task table

    @Test func silenceOnly() {
        #expect(segments(from: [(30, 0.1)], flush: true).isEmpty)
    }

    @Test func oneSegmentWithPreRoll() {
        // 15 quiet frames, 20 of speech, then 13 quiet ones that close the segment. The last 10 of the 15 quiet
        // frames come along as lead-in, so the segment starts at frame 5 and holds 10 + 20 + 13 = 43 frames.
        let found = segments(from: [(15, 0.1), (20, 0.9), (13, 0.1)])
        #expect(found.count == 1)
        #expect(found.first?.samples.count == 43 * 512)  // 22_016
        #expect(found.first?.startSample == 2_560)
    }

    @Test func blipDiscarded() {
        #expect(segments(from: [(15, 0.1), (5, 0.9), (13, 0.1)]).isEmpty)
    }

    @Test func longSpeechSplitsWithOverlap() {
        let found = segments(from: [(400, 0.9)], flush: true)
        #expect(found.map(\.startSample) == [0, 79_872, 159_744])
        #expect(found.map { $0.samples.count } == [188 * 512, 188 * 512, 88 * 512])
    }

    @Test func energyVAD() {
        var vad = EnergyVAD()
        let heardNoise = probabilities(&vad, for: noiseFrame(rms: 0.001), count: 50)
        #expect(heardNoise.allSatisfy { $0 == 0.1 })
        let heardLoud = probabilities(&vad, for: toneFrame(peak: 0.3), count: 10)
        #expect(heardLoud.allSatisfy { $0 == 0.9 })
    }

    @Test func realTimeGuard() {
        var watch = RealTimeGuard()
        var slow: [Bool] = []
        for _ in 0..<3 { slow.append(watch.record(processingSeconds: 0.9, audioSeconds: 1)) }
        #expect(slow == [false, false, true])
        let recovered = watch.record(processingSeconds: 0.5, audioSeconds: 1)
        #expect(!recovered)
        var again: [Bool] = []
        for _ in 0..<2 { again.append(watch.record(processingSeconds: 0.9, audioSeconds: 1)) }
        #expect(again == [false, false])
    }

    // MARK: Energy detector on a quiet input

    @Test func energyVADHearsAQuietMicrophone() {
        // macOS raw microphone-array mode can be about 20 dB quieter than usual: speech at -45 dBFS over very low
        // noise at -70 dBFS. Once the floor has followed the noise down, the speech must still stand out.
        var vad = EnergyVAD()
        let heardNoise = probabilities(&vad, for: noiseFrame(rms: rms(dBFS: -70)), count: 50)
        #expect(heardNoise.allSatisfy { $0 == 0.1 })
        let heardSpeech = probabilities(&vad, for: toneFrame(peak: peak(rmsDBFS: -45)), count: 10)
        #expect(heardSpeech.allSatisfy { $0 == 0.9 })
    }

    @Test func energyVADFloorFollowsTheNoiseDown() {
        // The floor starts at -60 dBFS, so a fixed limit would only hear sounds above -50. After 50 frames of
        // noise at -70 dBFS, a tone at -55 dBFS (15 dB above the noise) is speech, and the noise itself is not.
        var vad = EnergyVAD()
        let heardNoise = probabilities(&vad, for: noiseFrame(rms: rms(dBFS: -70)), count: 50)
        #expect(heardNoise.allSatisfy { $0 == 0.1 })
        let heardFaint = probabilities(&vad, for: toneFrame(peak: peak(rmsDBFS: -55)), count: 4)
        #expect(heardFaint.allSatisfy { $0 == 0.9 })
    }

    // MARK: Segmenter edges

    @Test func preRollOnlyHoldsAudioSinceThePreviousSegment() {
        // Segment 1 closes at frame 47. Three quiet frames later (48, 49, 50) speech starts at 51, so segment 2 starts
        // at frame 48: the lead-in never reuses the closing silence of segment 1.
        let found = segments(from: [(15, 0.1), (20, 0.9), (13, 0.1), (3, 0.1), (20, 0.9), (13, 0.1)])
        #expect(found.map(\.startSample) == startSamples(ofFrames: [5, 48]))
        #expect(found.map { $0.samples.count } == sampleCounts(ofFrames: [43, 36]))
    }

    @Test func segmentsHoldTheRightAudioInOrder() {
        // One segment: frames 5 to 47 (10 of lead-in, 20 of speech, 13 of closing silence).
        let one = segments(from: [(15, 0.1), (20, 0.9), (13, 0.1)], tagFrames: true)
        #expect(one.count == 1)
        #expect(one.first?.samples == taggedAudio(5..<48))

        // Splits: each new segment begins with the last 32 frames of the one before it.
        let long = segments(from: [(400, 0.9)], tagFrames: true, flush: true)
        #expect(long.count == 3)
        #expect(long.map(\.samples) == [taggedAudio(0..<188), taggedAudio(156..<344), taggedAudio(312..<400)])
    }

    @Test func aShortPauseDoesNotEndTheSegment() {
        // 12 quiet frames in the middle are bridged. The segment is 10 + 20 + 12 + 10 + 13 = 65 frames.
        let bridged = segments(from: [(15, 0.1), (20, 0.9), (12, 0.1), (10, 0.9), (13, 0.1)])
        #expect(bridged.map(\.startSample) == startSamples(ofFrames: [5]))
        #expect(bridged.map { $0.samples.count } == sampleCounts(ofFrames: [65]))

        // 13 quiet frames end it. The speech that follows starts a second segment right at frame 48.
        let split = segments(from: [(15, 0.1), (20, 0.9), (13, 0.1), (10, 0.9), (13, 0.1)])
        #expect(split.map(\.startSample) == startSamples(ofFrames: [5, 48]))
        #expect(split.map { $0.samples.count } == sampleCounts(ofFrames: [43, 23]))
    }

    @Test func closingSilenceBeatsTheLengthLimit() {
        // The tenth frame is both the third quiet one in a row and the one that makes the segment 10 frames long. The
        // segment ends there. It does not also start an overlap segment of mostly the same audio.
        let small = VADSegmenter(
            threshold: 0.8, minSpeechFrames: 2, minSilenceFrames: 3, maxSegmentFrames: 10, preRollFrames: 2,
            overlapFrames: 4)
        let found = segments(from: [(7, 0.9), (3, 0.1)], using: small, flush: true)
        #expect(found.map(\.startSample) == startSamples(ofFrames: [0]))
        #expect(found.map { $0.samples.count } == sampleCounts(ofFrames: [10]))
    }

    @Test func thresholdAndMinimumSpeechAreInclusive() {
        // A probability equal to the threshold is speech.
        #expect(segments(from: [(15, 0.1), (20, 0.5), (13, 0.1)]).count == 1)
        // 8 speech frames are enough. 7 are a blip.
        #expect(segments(from: [(15, 0.1), (8, 0.9), (13, 0.1)]).count == 1)
        #expect(segments(from: [(15, 0.1), (7, 0.9), (13, 0.1)]).isEmpty)
    }

    @Test func flushKeepsOnlyRealSpeech() {
        var open = VADSegmenter()
        for _ in 0..<12 { _ = open.push(frame: silentFrame, probability: 0.9) }
        let flushed = open.flush()
        #expect(flushed.map(\.startSample) == startSamples(ofFrames: [0]))
        #expect(flushed.map { $0.samples.count } == sampleCounts(ofFrames: [12]))
        let flushedAgain = open.flush()
        #expect(flushedAgain.isEmpty)  // nothing is handed out twice

        var blip = VADSegmenter()
        for _ in 0..<5 { _ = blip.push(frame: silentFrame, probability: 0.9) }
        let flushedBlip = blip.flush()
        #expect(flushedBlip.isEmpty)
    }

    @Test func customSettingsAreUsed() {
        let small = VADSegmenter(
            threshold: 0.8, minSpeechFrames: 2, minSilenceFrames: 3, maxSegmentFrames: 10, preRollFrames: 2,
            overlapFrames: 4)

        // 0.7 is below the 0.8 threshold. Speech starts at frame 5 with 2 frames of lead-in (3, 4) and the segment
        // closes after 3 quiet frames: 2 + 3 + 3 = 8 frames from frame 3.
        let closed = segments(from: [(5, 0.7), (3, 0.9), (3, 0.1)], using: small)
        #expect(closed.map(\.startSample) == startSamples(ofFrames: [3]))
        #expect(closed.map { $0.samples.count } == sampleCounts(ofFrames: [8]))

        // 25 frames of speech split at 10 frames, and each new segment starts with the last 4 frames of the one before.
        let split = segments(from: [(25, 0.9)], using: small, flush: true)
        #expect(split.map(\.startSample) == startSamples(ofFrames: [0, 6, 12, 18]))
        #expect(split.map { $0.samples.count } == sampleCounts(ofFrames: [10, 10, 10, 7]))
    }

    @Test func realTimeGuardKeepsWarningUntilItCatchesUp() {
        var watch = RealTimeGuard()
        for _ in 0..<3 { _ = watch.record(processingSeconds: 0.9, audioSeconds: 1) }
        let fourthSlow = watch.record(processingSeconds: 3, audioSeconds: 1)
        let atTheLimit = watch.record(processingSeconds: 0.8, audioSeconds: 1)
        let afterReset = watch.record(processingSeconds: 0.9, audioSeconds: 1)
        #expect(fourthSlow)  // still behind
        #expect(!atTheLimit)  // exactly at the limit is keeping up
        #expect(!afterReset)  // and the count started over

        // Its own settings. Audio with no length says nothing either way.
        var strict = RealTimeGuard(threshold: 0.5, consecutive: 2)
        let firstSlow = strict.record(processingSeconds: 0.6, audioSeconds: 1)
        let noAudio = strict.record(processingSeconds: 5, audioSeconds: 0)
        let secondSlow = strict.record(processingSeconds: 0.6, audioSeconds: 1)
        #expect(!firstSlow)
        #expect(!noAudio)
        #expect(secondSlow)
    }
}
