import NameAlertCore

/// When the `SFSpeechRecognizer` engine moves on to a new recognition task (spec section 8.4).
///
/// Apple ends a recognition task after about a minute of audio, so the engine starts a new one after 50 s of audio in
/// the current task. It also moves on when the task is done by itself (a final result) or has failed. The audio a new
/// task is primed with counts towards its 50 s.
struct RotationPolicy: Sendable {
    /// What happened to the current task.
    enum Event: Sendable, Equatable {
        /// It was given this many samples of audio.
        case audio(samples: Int)
        /// It reported what it heard.
        case result(isFinal: Bool)
        /// It failed.
        case failure
    }

    static let defaultMaxTaskSeconds = 50.0

    /// The most audio one task gets, in samples.
    let maxTaskSamples: Int
    /// The audio the current task has had, in samples.
    private(set) var taskSamples = 0

    init(maxTaskSeconds: Double = RotationPolicy.defaultMaxTaskSeconds) {
        maxTaskSamples = max(1, Int((maxTaskSeconds * AudioChunk.sampleRate).rounded()))
    }

    /// Whether the engine should start a new task after `event`. Audio is counted as it comes; once the task has had
    /// its 50 s, every further piece of audio says so too, until `rotated` is called.
    mutating func shouldRotate(after event: Event) -> Bool {
        switch event {
        case .audio(let samples):
            taskSamples += max(0, samples)
            return taskSamples >= maxTaskSamples
        case .result(let isFinal):
            return isFinal
        case .failure:
            return true
        }
    }

    /// A new task has started, already holding `primedSamples` of audio.
    mutating func rotated(primedSamples: Int = 0) {
        taskSamples = max(0, primedSamples)
    }
}
