import Foundation
import AVFoundation
import Speech

/// The orchestrator that wires `TranscriptionService` → `KeywordMatcher` →
/// `AlertCoordinator`. Owned by the SwiftUI app at top level.
@MainActor
final class ListeningEngine: ObservableObject {
    enum Status: Equatable {
        case stopped, requestingPermission, downloadingModel, listening, error(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastHit: Hit?

    private let settings: AppSettings
    private var transcription: TranscriptionService?
    private var matcher: KeywordMatcher
    private let coordinator = AlertCoordinator()
    private var pumpTasks: [Task<Void, Never>] = []

    init(settings: AppSettings) {
        self.settings = settings
        self.matcher = KeywordMatcher(
            keywords: settings.keywords,
            tolerance: settings.fuzzyTolerance,
            cooldownSeconds: settings.perKeywordCooldown
        )
    }

    func start() async {
        guard status != .listening, status != .downloadingModel else { return }
        status = .requestingPermission
        guard await ensurePermissions() else {
            status = .error("Microphone or speech permission denied.")
            return
        }
        await refreshConfiguration()

        let service = TranscriptionService(audioSource: settings.audioSource)
        self.transcription = service

        pumpTasks.forEach { $0.cancel() }
        pumpTasks = []
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await text in service.transcripts {
                await self.handleTranscript(text)
            }
        })
        pumpTasks.append(Task { [weak self] in
            guard let self else { return }
            for await state in service.states {
                await self.handleState(state)
            }
        })

        await service.start()
        status = .downloadingModel
    }

    func stop() async {
        pumpTasks.forEach { $0.cancel() }
        pumpTasks = []
        await transcription?.stop()
        transcription = nil
        status = .stopped
    }

    func toggle() async {
        if status == .listening || status == .downloadingModel {
            await stop()
        } else {
            await start()
        }
    }

    /// Re-read settings → rebuild matcher + coordinator. Call after any settings change.
    func refreshConfiguration() async {
        matcher = KeywordMatcher(
            keywords: settings.keywords,
            tolerance: settings.fuzzyTolerance,
            cooldownSeconds: settings.perKeywordCooldown
        )
        await coordinator.setAlerts(settings.enabledAlerts())
        await coordinator.setGlobalCooldown(settings.globalCooldown)
        await transcription?.setAudioSource(settings.audioSource)
    }

    /// Fire a single alert immediately (used by Settings "Test" buttons).
    func test(_ alert: Alert, sampleKeyword: String = "bala") async {
        let hit = Hit(keyword: sampleKeyword,
                      matchedText: "(test) \(sampleKeyword)",
                      timestamp: Date(),
                      distance: 0)
        await coordinator.test(alert, with: hit)
    }

    // MARK: - Private

    private func handleTranscript(_ text: String) async {
        lastTranscript = text
        let hits = matcher.ingest(cumulative: text)
        for hit in hits {
            lastHit = hit
            await coordinator.handle(hit)
        }
    }

    private func handleState(_ state: TranscriptionService.State) async {
        switch state {
        case .idle: status = .stopped
        case .downloading: status = .downloadingModel
        case .listening: status = .listening
        case .error(let message): status = .error(message)
        }
    }

    private func ensurePermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }
        // Mic permission is only needed for the microphone source. The system-audio
        // path uses ScreenCaptureKit, which prompts for Screen Recording on first
        // `SCStream.startCapture()` and does not require any mic entitlement.
        if settings.audioSource == .microphone {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return true
    }
}
