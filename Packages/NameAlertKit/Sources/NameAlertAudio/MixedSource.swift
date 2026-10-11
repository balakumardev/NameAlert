import Foundation
import NameAlertCore

/// Listens to two sources at once, typically system audio and the microphone, and mixes them into one stream, so a
/// single speech engine hears both.
///
/// `start()` starts `first`, then `second`; if `second` cannot start, `first` is stopped again and the error is
/// passed on. One task per source moves its chunks into an `AudioMixer` (inside a lock-protected `ChunkOutput`, so
/// the tasks never wait for this actor), and every mixed chunk is yielded with this source's own numbering. When
/// either source's stream ends, because it failed or was stopped, both sources are stopped and the mixed stream
/// finishes.
///
/// Starting and stopping await the two sources, so the actor alone would let commands interleave. A `SerialGate`
/// makes start, stop and the cleanup after a stream ends take turns, in arrival order, so the sources only ever see
/// the commands in that order.
public actor MixedSource: AudioCaptureSource {
    private struct Run {
        let id: UInt64
        let output: ChunkOutput<AudioMixer>
        /// One task per source, moving its chunks into `output`.
        let pumps: [Task<Void, Never>]
    }

    private let first: any AudioCaptureSource
    private let second: any AudioCaptureSource
    private let gate = SerialGate()
    private var run: Run?
    private var lastRunID: UInt64 = 0

    public init(first: any AudioCaptureSource, second: any AudioCaptureSource) {
        self.first = first
        self.second = second
    }

    public func start() async throws -> AsyncStream<AudioChunk> {
        await gate.enter()
        defer { gate.leave() }
        await endRun()

        let firstChunks = try await first.start()
        let secondChunks: AsyncStream<AudioChunk>
        do {
            secondChunks = try await second.start()
        } catch {
            await first.stop()
            throw error
        }

        lastRunID += 1
        let id = lastRunID
        let (chunks, continuation) = ChunkStream.make()
        let output = ChunkOutput(stage: AudioMixer(), continuation: continuation)
        // The mixed stream also ends when its consumer stops listening; then both sources are stopped.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.runEnded(id) }
        }
        run = Run(id: id, output: output, pumps: [
            pump(firstChunks, as: .first, into: output, run: id),
            pump(secondChunks, as: .second, into: output, run: id),
        ])
        return chunks
    }

    public func stop() async {
        await gate.enter()
        defer { gate.leave() }
        await endRun()
    }

    // MARK: Run lifecycle

    /// Moves one source's chunks into the mixer, off this actor. When that source's stream ends, the run ends.
    private func pump(
        _ chunks: AsyncStream<AudioChunk>, as input: MixerInput, into output: ChunkOutput<AudioMixer>, run id: UInt64
    ) -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await chunk in chunks {
                output.process { mixer in mixer.push(chunk.samples, from: input) }
            }
            await self?.runEnded(id)
        }
    }

    /// Ends the current run, if any: stops the pumps and both sources, then finishes the mixed stream. Call only
    /// while holding the gate.
    private func endRun() async {
        guard let current = run else { return }
        run = nil
        for pump in current.pumps {
            pump.cancel()
        }
        await first.stop()
        await second.stop()
        current.output.finish()
    }

    /// One of run `id`'s streams ended: a source stopped or failed, or the consumer went away. Ends the run if it is
    /// still the current one.
    private func runEnded(_ id: UInt64) async {
        await gate.enter()
        defer { gate.leave() }
        guard run?.id == id else { return }
        await endRun()
    }
}
