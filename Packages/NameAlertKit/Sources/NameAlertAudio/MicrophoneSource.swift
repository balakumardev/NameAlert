import AVFoundation
import Foundation
import NameAlertCore

/// Captures the current input device (the Mac's microphone, a headset, a USB mic) with `AVAudioEngine`.
///
/// A tap on the input node receives 4 096-frame buffers in the device's own format. The tap block runs on the
/// engine's thread and hands each buffer to the run's `ChunkOutput`, which converts it to 16 kHz mono, cuts it into
/// 100 ms chunks and yields them, all synchronously: the block never waits for this actor.
///
/// When the input or output hardware changes (a headset plugged in, the default input switched), the engine stops
/// itself and posts `.AVAudioEngineConfigurationChange`. The source then reinstalls the tap in the new format and
/// restarts the engine, and the same stream carries on. A run restarts at most 3 times in 10 s (`RestartBudget`).
/// If a restart fails, the budget runs out, or no input device is left, the stream finishes with a `.failed` end
/// reason; restarting with backoff is up to the caller.
///
/// Nothing in `start()`, `stop()` or the restart awaits, so each runs on the actor in one piece and they cannot
/// interleave. Callbacks that arrive late carry the number of the run they belong to and are ignored once that run
/// is over.
public actor MicrophoneSource: AudioCaptureSource {
    private static let tapFrames: AVAudioFrameCount = 4_096
    private static let log = Log.logger("audio")

    private struct Run {
        let id: UInt64
        let engine: AVAudioEngine
        let output: ChunkOutput<CaptureStage>
        let configurationObserver: any NSObjectProtocol
    }

    private var run: Run?
    private var lastRunID: UInt64 = 0
    /// Restarts of the current run after device changes. Reset by every `start()`.
    private var restartBudget = RestartBudget()
    /// Why the last run ended; read when no run is going.
    private var lastEndReason: CaptureEndReason?

    public init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        endRun(.stopped)
        lastRunID += 1
        let id = lastRunID

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // A sample rate of 0 is how the engine reports that there is no input device at all.
        guard Self.isUsable(input.outputFormat(forBus: 0)) else { throw AudioCaptureError.noInputDevice }

        let (stream, continuation) = ChunkStream.make()
        let output = ChunkOutput(continuation: continuation)
        // The stream also ends when its consumer stops listening; then the microphone is released.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.runEnded(id) }
        }
        // Watching starts before the engine does, so a device change during start-up is not missed. The handler
        // only schedules the restart on this actor; it must not touch the engine on the notification's queue.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { await self?.configurationChanged(run: id) }
        }

        Self.installTap(on: input, output: output)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            output.finish(reason: .failed(error.localizedDescription))
            throw AudioCaptureError.startFailed(error.localizedDescription)
        }

        restartBudget = RestartBudget()
        run = Run(id: id, engine: engine, output: output, configurationObserver: observer)
        return stream
    }

    public func stop() async {
        endRun(.stopped)
    }

    public func endReason() -> CaptureEndReason? {
        run == nil ? lastEndReason : nil
    }

    // MARK: Run lifecycle

    /// Ends the current run, if any, for `reason`: no more device-change handling, engine stopped, tap removed,
    /// then the stream finishes.
    private func endRun(_ reason: CaptureEndReason) {
        guard let current = run else { return }
        run = nil
        lastEndReason = current.output.recordEnd(reason)
        NotificationCenter.default.removeObserver(current.configurationObserver)
        current.engine.stop()
        current.engine.inputNode.removeTap(onBus: 0)
        current.output.finish(reason: reason)
    }

    /// A run's stream ended: stopped, failed, or its consumer went away. Releases the microphone if that run is
    /// still the current one, which only happens when the consumer went away.
    private func runEnded(_ id: UInt64) {
        guard run?.id == id else { return }
        endRun(.stopped)
    }

    /// The engine stopped itself because the hardware changed. Restarts run `id` in the new format, or ends it.
    private func configurationChanged(run id: UInt64) {
        guard let current = run, current.id == id else { return }
        // Changes come in bursts (a headset connecting can post several). If an earlier notification of the burst
        // already restarted the engine, it runs in the new format and there is nothing to do; checking this before
        // the budget keeps one burst from using the whole budget.
        guard !current.engine.isRunning else { return }
        guard restartBudget.allow(at: .now) else {
            Self.log.error("Microphone capture ended: the input device kept changing")
            endRun(.failed("Microphone kept changing"))
            return
        }

        let input = current.engine.inputNode
        input.removeTap(onBus: 0)
        guard Self.isUsable(input.outputFormat(forBus: 0)) else {
            Self.log.error("Microphone capture ended: no input device is left after a device change")
            endRun(.failed("Microphone disconnected"))
            return
        }
        Self.installTap(on: input, output: current.output)
        current.engine.prepare()
        do {
            try current.engine.start()
            Self.log.info("Microphone capture restarted after a device change")
        } catch {
            Self.log.error(
                "Microphone capture ended: restarting after a device change failed: \(error.localizedDescription, privacy: .public)")
            endRun(.failed(error.localizedDescription))
        }
    }

    // MARK: Helpers

    /// Installs the tap that feeds `output`.
    ///
    /// This is a static function on purpose: a closure written inside the actor would be isolated to it (the tap
    /// block type is not `Sendable`), and Swift traps when the engine then calls it on its own thread. Formed here,
    /// the block is not isolated and only touches the lock-protected output.
    ///
    /// `format: nil` taps the bus in whatever format it has at this moment. A format read a moment earlier would make
    /// the engine raise an exception if the device changed in between.
    private static func installTap(on input: AVAudioInputNode, output: ChunkOutput<CaptureStage>) {
        input.installTap(onBus: 0, bufferSize: tapFrames, format: nil) { buffer, _ in
            output.push(buffer)
        }
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }
}
