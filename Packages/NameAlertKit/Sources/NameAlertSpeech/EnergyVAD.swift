import Foundation

/// A simple speech detector, for when the Silero model cannot be loaded.
///
/// A frame counts as speech when it is clearly louder than the background noise. The noise level is learned as the
/// frames arrive: it starts at -60 dBFS, drops at once to any quieter frame, and otherwise creeps up by 0.5 dB per
/// frame. So it works the same on a quiet microphone as in a noisy room.
public struct EnergyVAD: Sendable {
    /// How far above the noise level a frame has to be to count as speech.
    private static let marginDB = 10.0
    /// How much the noise level may rise per frame.
    private static let riseDB = 0.5

    private var noiseFloorDB = -60.0

    public init() {}

    /// 0.9 when the frame is speech, 0.1 when it is not. Frames should come in order: the noise level follows them.
    public mutating func probability(for frame: [Float]) -> Float {
        var sumOfSquares = 0.0
        for sample in frame { sumOfSquares += Double(sample) * Double(sample) }
        let rms = frame.isEmpty ? 0 : (sumOfSquares / Double(frame.count)).squareRoot()
        let level = 20 * log10(rms + 1e-9)  // dBFS: 0 is full scale

        if level < noiseFloorDB {
            noiseFloorDB = level
        } else {
            noiseFloorDB += Self.riseDB
        }
        return level > noiseFloorDB + Self.marginDB ? 0.9 : 0.1
    }
}
