import AVFoundation
import Foundation
import NameAlertCore

// MARK: - Contract

/// Something that captures audio and delivers it as 100 ms chunks of 16 kHz mono samples.
///
/// - `start()` begins a run and returns its stream. Chunks are numbered from 0 in every run. If the source is already
///   running, the old run is stopped first and its stream finishes. A source that cannot start throws, usually an
///   `AudioCaptureError`.
/// - The stream finishes when the source is stopped, when capture fails, or when the consumer cancels its iteration
///   (which also releases the device). It keeps the newest 50 chunks (about 5 s) for a consumer that falls behind.
/// - `stop()` ends the current run and finishes its stream. Stopping a stopped source does nothing, and `start()`
///   after `stop()` begins a new run.
/// - Restarting after a failure, with backoff, is up to the caller.
public protocol AudioCaptureSource: Sendable {
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

/// Why a capture source could not start.
public enum AudioCaptureError: Error, Equatable {
    /// There is no microphone or other input device.
    case noInputDevice
    /// ScreenCaptureKit found no display to attach the capture to.
    case noDisplay
    /// The user has not allowed screen and system audio recording.
    case permissionDenied
    /// Anything else, with the system's description.
    case startFailed(String)
}

/// Makes the capture source for each `AudioSourceKind`.
public enum AudioCaptureFactory {
    /// A new, stopped source. `.both` mixes system audio (first input) with the microphone (second input).
    public static func make(_ kind: AudioSourceKind) -> any AudioCaptureSource {
        switch kind {
        case .systemAudio: SystemAudioSource()
        case .microphone: MicrophoneSource()
        case .both: MixedSource(first: SystemAudioSource(), second: MicrophoneSource())
        }
    }
}

// MARK: - Shared plumbing for the sources

/// The stream every source hands out.
enum ChunkStream {
    /// About 5 s of audio. When a consumer stalls, the oldest chunks are dropped, so memory stays bounded.
    static let bufferedChunks = 50

    static func make() -> (stream: AsyncStream<AudioChunk>, continuation: AsyncStream<AudioChunk>.Continuation) {
        AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(bufferedChunks))
    }
}

/// The end of a run's pipeline that real-time code talks to: it turns input into numbered chunks and yields them.
///
/// Capture callbacks (an `AVAudioEngine` tap, a ScreenCaptureKit sample handler) and `MixedSource`'s pump tasks run
/// on their own threads and must not wait for an actor. They call `process(_:)`, which runs the `Stage` (converter
/// and chunk assembler, or mixer), numbers the chunks and yields them, synchronously and under one lock, so chunks
/// leave in order even if two threads push at once.
///
/// The owning actor creates the output when a run starts and finishes it when the run ends. After `finish()`,
/// `process(_:)` does nothing, so a callback that fires while its run is torn down is harmless. Each run gets a new
/// output: a fresh converter, no leftover samples and numbering from 0.
final class ChunkOutput<Stage>: @unchecked Sendable {
    private let lock = NSLock()
    /// All guarded by `lock`.
    private var stage: Stage
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var nextSequence: UInt64 = 0

    init(stage: Stage, continuation: AsyncStream<AudioChunk>.Continuation) {
        self.stage = stage
        self.continuation = continuation
    }

    /// Runs `body` on the stage and yields the whole chunks it returns. Does nothing once the output is finished.
    func process(_ body: (inout Stage) -> [[Float]]) {
        lock.withLock {
            guard let continuation else { return }
            for samples in body(&stage) {
                continuation.yield(AudioChunk(samples: samples, sequence: nextSequence))
                nextSequence += 1
            }
        }
    }

    /// Finishes the stream. Later calls, and later `process(_:)` calls, do nothing.
    func finish() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        // Outside the lock: finishing runs the stream's termination handler.
        continuation?.finish()
    }
}

/// What a device source does to each captured buffer: convert it to 16 kHz mono, then cut it into 100 ms chunks.
struct CaptureStage {
    let converter = AudioFormatConverter()
    var assembler = ChunkAssembler()
}

extension ChunkOutput where Stage == CaptureStage {
    convenience init(continuation: AsyncStream<AudioChunk>.Continuation) {
        self.init(stage: CaptureStage(), continuation: continuation)
    }

    /// Converts a captured buffer, cuts it into chunks and yields them. Called on the capture thread; never waits
    /// for an actor.
    func push(_ buffer: AVAudioPCMBuffer) {
        process { stage in
            let samples = stage.converter.convert(buffer)
            return stage.assembler.push(samples)
        }
    }
}

/// Lets an actor run its start and stop commands one at a time, in the order they arrive.
///
/// An actor alone does not do that: while one command awaits (ScreenCaptureKit starting, a sub-source stopping), the
/// actor runs other calls, so a `stop()` could land in the middle of a `start()` and the two would undo each other's
/// work. Commands that `enter()` first thing and `leave()` when done never overlap.
///
/// Only its owning actor uses it (`enter` runs in the caller's isolation), so it needs no lock. A command that holds
/// the gate must never wait for something that itself needs the same gate.
final class SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once the caller holds the gate. Not cancellable: a waiting command still runs.
    func enter(isolation: isolated (any Actor) = #isolation) async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the command that has waited longest, or opens it.
    func leave() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
