import NameAlertCore

/// Which of the mixer's two inputs a push belongs to.
public enum MixerInput: Sendable { case first, second }

/// Mixes two 16 kHz mono streams into one stream of fixed-size chunks.
///
/// Each input has its own queue. While both queues hold a whole chunk, their sum is emitted, clamped to -1...1. If
/// one input stops delivering, the other would wait for it forever, so once the other input holds
/// `starvationSamples` (300 ms by default) and this one holds nothing at all, the other is emitted on its own, as if
/// this one were silent, until less than a chunk of it is left.
///
/// Inputs are expected to push whole chunks, which is what every capture source emits. A leftover fragment on an
/// input that has stopped counts as "not empty" and would hold the other input back.
///
/// A plain value type with no locking: whoever owns it decides how calls are serialized.
public struct AudioMixer: Sendable {
    private let chunkSamples: Int
    private let starvationSamples: Int
    private var firstQueue: [Float] = []
    private var secondQueue: [Float] = []

    /// A `chunkSamples` below 1 counts as 1, so a bad value cannot make `push` loop forever or crash.
    public init(chunkSamples: Int = AudioChunk.samplesPerChunk, starvationSamples: Int = 4_800) {
        self.chunkSamples = max(1, chunkSamples)
        self.starvationSamples = starvationSamples
    }

    /// Adds `samples` to one input's queue and returns every chunk that is now ready, oldest first.
    public mutating func push(_ samples: [Float], from input: MixerInput) -> [[Float]] {
        switch input {
        case .first: firstQueue.append(contentsOf: samples)
        case .second: secondQueue.append(contentsOf: samples)
        }

        var chunks: [[Float]] = []
        // How much of each queue has been emitted so far. The queues are trimmed once at the end, not per chunk.
        var firstUsed = 0
        var secondUsed = 0

        // Both inputs have a whole chunk: add them.
        while firstQueue.count - firstUsed >= chunkSamples, secondQueue.count - secondUsed >= chunkSamples {
            chunks.append((0 ..< chunkSamples).map { offset in
                Self.clamped(firstQueue[firstUsed + offset] + secondQueue[secondUsed + offset])
            })
            firstUsed += chunkSamples
            secondUsed += chunkSamples
        }

        // One input has delivered nothing while the other has piled up 300 ms: let the other through alone.
        if secondQueue.count == secondUsed, firstQueue.count - firstUsed >= starvationSamples {
            Self.drain(firstQueue, used: &firstUsed, chunkSamples: chunkSamples, into: &chunks)
        } else if firstQueue.count == firstUsed, secondQueue.count - secondUsed >= starvationSamples {
            Self.drain(secondQueue, used: &secondUsed, chunkSamples: chunkSamples, into: &chunks)
        }

        firstQueue.removeFirst(firstUsed)
        secondQueue.removeFirst(secondUsed)
        return chunks
    }

    /// Emits whole chunks from `queue`, starting after the `used` samples already taken, until less than a chunk is left.
    private static func drain(_ queue: [Float], used: inout Int, chunkSamples: Int, into chunks: inout [[Float]]) {
        while queue.count - used >= chunkSamples {
            chunks.append(queue[used ..< used + chunkSamples].map(clamped))
            used += chunkSamples
        }
    }

    private static func clamped(_ sample: Float) -> Float {
        min(1, max(-1, sample))
    }
}
