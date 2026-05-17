import Foundation
@preconcurrency import AVFoundation
import Speech

/// Wraps Apple's `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) into a long-lived
/// streaming transcription pipeline. Audio is sourced either from the system
/// microphone (`AVAudioEngine`) or from system audio output (`SCStream` via
/// `SystemAudioCapture`). Yields cumulative formatted transcripts via
/// `transcripts` (an `AsyncStream<String>`).
actor TranscriptionService {
    enum State: Sendable { case idle, downloading, listening, error(String) }

    /// Public stream of transcript text (each value is the latest `formattedString`).
    let transcripts: AsyncStream<String>
    /// Public stream of state changes for UI.
    let states: AsyncStream<State>

    private let transcriptsContinuation: AsyncStream<String>.Continuation
    private let statesContinuation: AsyncStream<State>.Continuation

    private var audioEngine: AVAudioEngine?
    private var systemCapture: SystemAudioCapture?
    private var captureTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartDelay: UInt64 = 1_000_000_000 // 1s, doubled up to 30s
    private var locale: Locale
    private var audioSource: AudioSource
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(locale: Locale = .current, audioSource: AudioSource = .systemAudio) {
        self.locale = locale
        self.audioSource = audioSource
        var tCont: AsyncStream<String>.Continuation!
        self.transcripts = AsyncStream { tCont = $0 }
        self.transcriptsContinuation = tCont
        var sCont: AsyncStream<State>.Continuation!
        self.states = AsyncStream { sCont = $0 }
        self.statesContinuation = sCont
    }

    deinit {
        transcriptsContinuation.finish()
        statesContinuation.finish()
    }

    func start() async {
        await stop()
        statesContinuation.yield(.downloading)
        do {
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            self.transcriber = transcriber

            if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installRequest.downloadAndInstall()
            }

            let (inputSequence, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            self.inputContinuation = inputCont
            let analyzer = SpeechAnalyzer(inputSequence: inputSequence, modules: [transcriber])
            self.analyzer = analyzer

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw NSError(domain: "TranscriptionService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "No compatible audio format for transcriber"])
            }
            self.analyzerFormat = format

            try await startCapture(targetFormat: format)
            statesContinuation.yield(.listening)
            restartDelay = 1_000_000_000

            resultsTask = Task { [weak self] in
                guard let self else { return }
                await self.consumeResults(transcriber: transcriber)
            }
        } catch {
            statesContinuation.yield(.error(error.localizedDescription))
            scheduleRestart()
        }
    }

    func stop() async {
        restartTask?.cancel(); restartTask = nil
        resultsTask?.cancel(); resultsTask = nil
        captureTask?.cancel(); captureTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        if let capture = systemCapture {
            await capture.stop()
        }
        systemCapture = nil
        inputContinuation?.finish()
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        converter = nil
        statesContinuation.yield(.idle)
    }

    func setLocale(_ locale: Locale) async {
        self.locale = locale
        if audioEngine != nil || systemCapture != nil { await start() }
    }

    func setAudioSource(_ source: AudioSource) async {
        guard source != audioSource else { return }
        self.audioSource = source
        if audioEngine != nil || systemCapture != nil { await start() }
    }

    // MARK: - Private

    private func consumeResults(transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty {
                    transcriptsContinuation.yield(text)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            statesContinuation.yield(.error(error.localizedDescription))
            scheduleRestart()
        }
    }

    private func startCapture(targetFormat: AVAudioFormat) async throws {
        switch audioSource {
        case .microphone:
            try setupAudioEngine(targetFormat: targetFormat)
            try audioEngine?.start()
        case .systemAudio:
            let capture = SystemAudioCapture()
            try await capture.start(sampleRate: 48_000, channelCount: 1)
            self.systemCapture = capture
            captureTask = Task { [weak self] in
                guard let self else { return }
                for await buffer in await capture.buffers {
                    await self.feedAnalyzer(buffer: buffer, targetFormat: targetFormat)
                }
            }
        }
    }

    private func setupAudioEngine(targetFormat: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { await self.feedAnalyzer(buffer: buffer, targetFormat: targetFormat) }
        }
        engine.prepare()
        self.audioEngine = engine
    }

    /// Feeds an arbitrary input buffer (mic tap or SCStream sample) to the
    /// analyzer, converting on demand. The converter is rebuilt if the input
    /// format changes (which can happen with system audio when the user
    /// switches output devices).
    private func feedAnalyzer(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let cont = inputContinuation else { return }
        let inputFormat = buffer.format
        let needsConversion = !(inputFormat.sampleRate == targetFormat.sampleRate
            && inputFormat.channelCount == targetFormat.channelCount
            && inputFormat.commonFormat == targetFormat.commonFormat)
        if !needsConversion {
            cont.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil
            || converter?.inputFormat.sampleRate != inputFormat.sampleRate
            || converter?.inputFormat.channelCount != inputFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return }
        cont.yield(AnalyzerInput(buffer: out))
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30_000_000_000)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.start()
        }
    }
}


