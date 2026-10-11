/// Notices when the local model is not keeping up with the audio.
///
/// After each stretch of audio is recognized, `record` is told how long that took and how long the audio lasted.
/// Several slow stretches in a row mean the model is falling behind.
public struct RealTimeGuard: Sendable {
    private let threshold: Double
    private let consecutive: Int
    /// How many of the latest stretches in a row were slower than the threshold, counted up to `consecutive`.
    private var slowInARow = 0

    /// By default a stretch is slow when recognizing it took more than 0.8 of its own length, and the model is falling
    /// behind after 3 of those in a row.
    public init(threshold: Double = 0.8, consecutive: Int = 3) {
        self.threshold = threshold
        self.consecutive = max(1, consecutive)
    }

    /// Returns true while the model is falling behind: the latest `consecutive` stretches were all slow, which stays
    /// true for as long as they keep being slow. One stretch at or under the threshold starts the count over. Audio
    /// with no length says nothing, so it changes nothing.
    public mutating func record(processingSeconds: Double, audioSeconds: Double) -> Bool {
        if audioSeconds > 0 {
            if processingSeconds / audioSeconds > threshold {
                slowInARow = min(slowInARow + 1, consecutive)
            } else {
                slowInARow = 0
            }
        }
        return slowInARow >= consecutive
    }
}
