import Foundation

/// A stretch of speech cut out of the audio, ready to be recognized.
public struct SpeechSegment: Sendable, Equatable {
    /// Where the segment starts, in samples from the first sample the segmenter was given.
    public let startSample: Int64
    /// The audio, 16 kHz mono. It starts a little before the first word and, when the speech stopped on its own,
    /// it ends with the silence that closed it.
    public let samples: [Float]

    public init(startSample: Int64, samples: [Float]) {
        self.startSample = startSample
        self.samples = samples
    }
}

/// Cuts audio into stretches of speech, one frame at a time.
///
/// A voice activity detector (Silero, or `EnergyVAD` when the Silero model is missing) gives every frame a speech
/// probability. The segmenter decides from those where speech starts and stops:
/// - While nothing is going on it remembers the last `preRollFrames` frames.
/// - A frame with a probability of at least `threshold` starts a segment. The remembered frames come first, so the
///   segment begins a little before the first word.
/// - The segment ends once `minSilenceFrames` frames in a row are below the threshold. It is handed out only if it
///   had at least `minSpeechFrames` speech frames. A shorter blip is dropped.
/// - A segment that grows to `maxSegmentFrames` is handed out, and the next one starts with its last `overlapFrames`
///   frames, so a word cut by the split is whole in the next segment.
///
/// Frames are `frameSamples` long and are numbered from 0 in the order they are pushed.
public struct VADSegmenter: Sendable {
    /// 32 ms at 16 kHz, the frame size the Silero detector works on.
    public static let frameSamples = 512

    private let threshold: Float
    private let minSpeechFrames: Int
    private let minSilenceFrames: Int
    private let maxSegmentFrames: Int
    private let preRollFrames: Int
    private let overlapFrames: Int

    /// The number of the next frame to arrive.
    private var nextFrame: Int64 = 0
    /// While no segment is open: the latest frames, oldest first. It is empty from the moment a segment starts until
    /// that segment ends, then fills again from the frames that come after it.
    private var preRoll: [[Float]] = []
    /// The segment being collected, if there is one.
    private var open: OpenSegment?

    private struct OpenSegment: Sendable {
        /// The number of the segment's first frame.
        var firstFrame: Int64
        var frames: [[Float]]
        var speechFrames: Int
        /// How many of the latest frames in a row were below the threshold.
        var silenceRun: Int
    }

    /// The defaults are the spec's times in whole frames of 32 ms: at least 8 speech frames (about 250 ms), a segment
    /// closes after 13 quiet frames (about 400 ms) or at 188 frames (about 6 s), with 10 frames of lead-in (about
    /// 300 ms) and 32 frames of overlap between forced splits (about 1 s).
    ///
    /// Values that could never work are adjusted: at least one frame of silence ends a segment, and the overlap is
    /// always shorter than the segment, so a split moves forward.
    public init(
        threshold: Float = 0.5, minSpeechFrames: Int = 8, minSilenceFrames: Int = 13,
        maxSegmentFrames: Int = 188, preRollFrames: Int = 10, overlapFrames: Int = 32
    ) {
        let longest = max(1, maxSegmentFrames)
        self.threshold = threshold
        self.minSpeechFrames = minSpeechFrames
        self.minSilenceFrames = max(1, minSilenceFrames)
        self.maxSegmentFrames = longest
        self.preRollFrames = max(0, preRollFrames)
        self.overlapFrames = min(max(0, overlapFrames), longest - 1)
    }

    /// Takes the next frame and the speech probability the detector gave it. Returns the segments that are complete
    /// now: none, or one.
    public mutating func push(frame: [Float], probability: Float) -> [SpeechSegment] {
        let number = nextFrame
        nextFrame += 1
        let isSpeech = probability >= threshold

        guard var segment = open else {
            guard isSpeech else {
                remember(frame)
                return []
            }
            // Speech after quiet: start a segment with the remembered frames and this one.
            let leadIn = preRoll
            preRoll.removeAll(keepingCapacity: true)
            return settle(
                OpenSegment(
                    firstFrame: number - Int64(leadIn.count), frames: leadIn + [frame], speechFrames: 1, silenceRun: 0))
        }

        open = nil  // so the append below works on the only copy of the frames
        segment.frames.append(frame)
        if isSpeech {
            segment.speechFrames += 1
            segment.silenceRun = 0
        } else {
            segment.silenceRun += 1
        }
        return settle(segment)
    }

    /// Ends the audio: hands out the segment that is still open, if it has enough speech.
    public mutating func flush() -> [SpeechSegment] {
        guard let segment = open else { return [] }
        open = nil
        return handedOut(segment)
    }

    /// Decides what a segment that has just taken a frame does next: end, split in two, or go on. When the closing
    /// silence and the length limit arrive on the same frame, the segment ends.
    private mutating func settle(_ segment: OpenSegment) -> [SpeechSegment] {
        if segment.silenceRun >= minSilenceFrames {
            return handedOut(segment)
        }
        if segment.frames.count >= maxSegmentFrames {
            let overlap = Array(segment.frames.suffix(overlapFrames))
            open = OpenSegment(
                firstFrame: segment.firstFrame + Int64(segment.frames.count - overlap.count),
                frames: overlap, speechFrames: overlapFrames, silenceRun: 0)
            return handedOut(segment)
        }
        open = segment
        return []
    }

    /// The segment as something to give out, or nothing when it had too little speech.
    private func handedOut(_ segment: OpenSegment) -> [SpeechSegment] {
        guard segment.speechFrames >= minSpeechFrames else { return [] }
        return [
            SpeechSegment(
                startSample: segment.firstFrame * Int64(Self.frameSamples), samples: Array(segment.frames.joined()))
        ]
    }

    /// Keeps a quiet frame as possible lead-in, dropping the oldest once `preRollFrames` are held.
    private mutating func remember(_ frame: [Float]) {
        guard preRollFrames > 0 else { return }
        if preRoll.count == preRollFrames { preRoll.removeFirst() }
        preRoll.append(frame)
    }
}
