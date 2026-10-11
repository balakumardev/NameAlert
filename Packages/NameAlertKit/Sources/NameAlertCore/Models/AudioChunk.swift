/// 100 ms of 16 kHz mono audio, the unit every capture source produces.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate = 16_000.0
    public static let samplesPerChunk = 1_600

    public let samples: [Float]
    public let sequence: UInt64
    /// Root-mean-square level of `samples`; 0 for an empty chunk.
    public let rms: Float

    public init(samples: [Float], sequence: UInt64) {
        self.samples = samples
        self.sequence = sequence
        if samples.isEmpty {
            rms = 0
        } else {
            let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            rms = Float((energy / Double(samples.count)).squareRoot())
        }
    }
}
