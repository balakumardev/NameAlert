import Foundation
import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia

/// Captures system audio output (speakers/headphones) via `ScreenCaptureKit`.
/// Yields `AVAudioPCMBuffer`s on the `buffers` stream. Excludes our own process
/// so we don't capture feedback from our own alert sounds.
///
/// Requires Screen Recording permission (System Settings → Privacy & Security →
/// Screen & System Audio Recording). macOS will prompt on first `start()`.
actor SystemAudioCapture {
    let buffers: AsyncStream<AVAudioPCMBuffer>
    private let buffersCont: AsyncStream<AVAudioPCMBuffer>.Continuation

    private var stream: SCStream?
    private var output: SystemAudioStreamOutput?

    init() {
        var c: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.buffers = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        self.buffersCont = c
    }

    func start(sampleRate: Int = 48_000, channelCount: Int = 1) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for SCStream"])
        }

        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let selfApps = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: selfApps,
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        config.excludesCurrentProcessAudio = true
        // SCStream still requires a video config even when only audio is consumed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let cont = self.buffersCont
        let bridge = SystemAudioStreamOutput { sampleBuffer in
            guard let buffer = SystemAudioCapture.makePCMBuffer(from: sampleBuffer) else { return }
            cont.yield(buffer)
        }
        self.output = bridge

        let stream = SCStream(filter: filter, configuration: config, delegate: bridge)
        try stream.addStreamOutput(bridge, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "dev.balakumar.NameAlert.systemAudio",
                                                                     qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        output = nil
        buffersCont.finish()
    }

    /// Convert a CoreMedia audio sample buffer to an `AVAudioPCMBuffer`.
    nonisolated static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(numSamples),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Bridges Objective-C SCStream callbacks into a Swift closure. Marked
/// `@unchecked Sendable` because callbacks come on a dedicated dispatch queue
/// and the only state we hold is an immutable closure.
private final class SystemAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let onAudio: @Sendable (CMSampleBuffer) -> Void

    init(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onAudio = onAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onAudio(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudioCapture stopped with error: \(error.localizedDescription)")
    }
}
