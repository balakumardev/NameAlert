import NameAlertCore

/// Cuts samples that arrive in pieces of any size into chunks of a fixed size and keeps the rest for next time.
///
/// A plain value type with no locking: whoever owns it decides how calls are serialized.
public struct ChunkAssembler: Sendable {
    private let chunkSamples: Int
    private var pending: [Float] = []

    /// A `chunkSamples` below 1 counts as 1, so a bad value cannot make `push` loop forever or crash.
    public init(chunkSamples: Int = AudioChunk.samplesPerChunk) {
        self.chunkSamples = max(1, chunkSamples)
    }

    /// Adds `samples` and returns every chunk that is now complete, oldest first. Samples that do not fill a whole
    /// chunk stay inside and start the next one.
    public mutating func push(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        let chunkCount = pending.count / chunkSamples
        guard chunkCount > 0 else { return [] }
        let chunks = (0 ..< chunkCount).map { index in
            Array(pending[index * chunkSamples ..< (index + 1) * chunkSamples])
        }
        pending.removeFirst(chunkCount * chunkSamples)
        return chunks
    }
}
