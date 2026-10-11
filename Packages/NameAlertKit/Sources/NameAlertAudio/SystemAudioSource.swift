import AVFoundation
import CoreMedia
import Foundation
import NameAlertCore
import ScreenCaptureKit

/// Captures what the Mac plays (calls, videos, music) with ScreenCaptureKit, leaving out NameAlert's own sounds.
///
/// The stream captures 48 kHz mono audio from the first display, with our app excluded from the filter and
/// `excludesCurrentProcessAudio` set, so alert sounds never come back as input. ScreenCaptureKit insists on video as
/// well, so it gets the smallest and slowest video it accepts (2 × 2 pixels, one frame a second).
///
/// Audio arrives on a serial queue of our own and goes straight to the run's `ChunkOutput`, which converts it to
/// 16 kHz mono, cuts it into 100 ms chunks and yields them without waiting for this actor. When ScreenCaptureKit
/// stops the stream with an error, the output is finished there and then, and the stream ends.
///
/// Starting and stopping await ScreenCaptureKit, so the actor alone would let a `stop()` run in the middle of a
/// `start()`. A `SerialGate` makes start, stop and the cleanup after a stream ends take turns, in arrival order.
public actor SystemAudioSource: AudioCaptureSource {
    private static let log = Log.logger("audio")

    private struct Run {
        let id: UInt64
        let stream: SCStream
        /// Receives the stream's audio and errors. Kept here because the stream holds its delegate weakly.
        let receiver: SystemAudioReceiver
        let output: ChunkOutput<CaptureStage>
    }

    private let gate = SerialGate()
    private var run: Run?
    private var lastRunID: UInt64 = 0

    public init() {}

    public func start() async throws -> AsyncStream<AudioChunk> {
        await gate.enter()
        defer { gate.leave() }
        await endRun()
        lastRunID += 1
        let id = lastRunID

        let filter: SCContentFilter
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
            let ownBundleID = Bundle.main.bundleIdentifier
            let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        } catch {
            throw Self.captureError(for: error)
        }

        let (chunks, continuation) = ChunkStream.make()
        let output = ChunkOutput(continuation: continuation)
        // Set before capture starts, so every way the stream can end (stop, a capture error, the consumer going
        // away) reaches `runEnded`, which releases the capture if this run is still the current one.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.runEnded(id) }
        }
        let receiver = SystemAudioReceiver(output: output)
        let stream = SCStream(filter: filter, configuration: Self.makeConfiguration(), delegate: receiver)
        do {
            try stream.addStreamOutput(
                receiver, type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "dev.balakumar.namealert.systemAudio", qos: .userInitiated))
            try await stream.startCapture()
        } catch {
            output.finish()
            throw Self.captureError(for: error)
        }

        run = Run(id: id, stream: stream, receiver: receiver, output: output)
        return chunks
    }

    public func stop() async {
        await gate.enter()
        defer { gate.leave() }
        await endRun()
    }

    // MARK: Run lifecycle

    /// Stops the current run, if any, then finishes its stream. Call only while holding the gate.
    private func endRun() async {
        guard let current = run else { return }
        run = nil
        do {
            try await current.stream.stopCapture()
        } catch {
            // Expected when ScreenCaptureKit already stopped the stream (it reported an error): nothing to release.
            Self.log.debug("Stopping system audio capture: \(error.localizedDescription, privacy: .public)")
        }
        current.output.finish()
    }

    /// A run's stream ended: stopped, failed, or its consumer went away. Releases the capture if that run is still
    /// the current one.
    private func runEnded(_ id: UInt64) async {
        await gate.enter()
        defer { gate.leave() }
        guard run?.id == id else { return }
        await endRun()
    }

    // MARK: Helpers

    /// Same settings as the original prototype.
    private static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 6
        return configuration
    }

    /// The user declining (or having denied) screen recording becomes `.permissionDenied`, a missing display
    /// `.noDisplay`, and anything else `.startFailed` with the system's description.
    private static func captureError(for error: any Error) -> AudioCaptureError {
        if let error = error as? AudioCaptureError { return error }
        if let error = error as? SCStreamError {
            switch error.code {
            case .userDeclined: return .permissionDenied
            case .noDisplayList: return .noDisplay
            default: break
            }
        }
        return .startFailed(error.localizedDescription)
    }
}

/// Receives ScreenCaptureKit's callbacks for one run, on the run's sample handler queue, and hands the audio straight
/// to the run's output.
private final class SystemAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private static let log = Log.logger("audio")

    private let output: ChunkOutput<CaptureStage>

    init(output: ChunkOutput<CaptureStage>) {
        self.output = output
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        output.push(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.log.error("System audio capture stopped: \(error.localizedDescription, privacy: .public)")
        output.finish()
    }

    /// Copies a CoreMedia audio sample buffer into an `AVAudioPCMBuffer` in the same format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
