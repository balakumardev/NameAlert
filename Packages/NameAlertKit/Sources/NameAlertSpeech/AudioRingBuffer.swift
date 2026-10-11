/// The newest stretch of audio, kept so a new recognition task can hear it again (spec section 8.4).
///
/// It holds the last `capacity` samples and forgets the ones before. Appending costs as much as the samples appended;
/// reading `contents` copies them out, oldest first.
struct AudioRingBuffer: Sendable {
    /// 1.5 s of 16 kHz audio.
    static let defaultCapacity = 24_000

    let capacity: Int
    private var storage: [Float]
    /// Where the oldest sample is in `storage`.
    private var head = 0
    /// How many samples it holds, at most `capacity`.
    private(set) var count = 0

    init(capacity: Int = AudioRingBuffer.defaultCapacity) {
        self.capacity = max(0, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Adds `samples` after the ones it holds, dropping the oldest when it is full.
    mutating func append(_ samples: [Float]) {
        guard capacity > 0 else { return }
        // Of a block longer than the buffer, only the end can stay.
        for sample in samples.suffix(capacity) {
            if count < capacity {
                storage[(head + count) % capacity] = sample
                count += 1
            } else {
                storage[head] = sample
                head = (head + 1) % capacity
            }
        }
    }

    /// The samples it holds, oldest first.
    var contents: [Float] {
        guard count > 0 else { return [] }
        let end = head + count
        if end <= capacity { return Array(storage[head..<end]) }
        return Array(storage[head...]) + Array(storage[..<(end - capacity)])
    }
}
