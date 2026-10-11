import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech

/// What the Alerts and Speech renders need beyond a demo controller: models that are installed or being downloaded,
/// notifications that are not allowed yet, and channels whose last delivery failed. Everything runs on the inert
/// stand-ins, so nothing is captured, recognized, downloaded or sent.
@MainActor
enum SettingsFixtures {
    /// A Mac with macOS 26 and these languages for every Apple engine.
    static let capabilities = EngineCapabilities(
        osMajorVersion: 26, speechTranscriberAvailable: true,
        speechTranscriberLocales: ["de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "it-IT", "ja-JP", "pt-BR"],
        dictationTranscriberLocales: ["de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "it-IT", "ja-JP", "pt-BR"],
        sfSpeechOnDeviceLocales: ["en-US", "de-DE"], isAppleSilicon: true)

    /// A Mac that macOS 14 runs, where Apple's engines know no language on the device.
    static let capabilitiesWithoutApple = EngineCapabilities(
        osMajorVersion: 14, speechTranscriberAvailable: false, speechTranscriberLocales: [],
        dictationTranscriberLocales: [], sfSpeechOnDeviceLocales: [], isAppleSilicon: false)

    /// The Alerts settings of someone who has set up ntfy, Telegram and a webhook (whose address is not allowed).
    static var alertsConfiguration: AppConfiguration {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.channels.ntfy.topic = "bala-alerts-7f3k"
        configuration.channels.telegramCall.user = "@balakumar"
        configuration.channels.webhook.url = "http://hooks.example.com/namealert"
        configuration.channels.webhook.headerNames = ["X-Api-Key", "X-Team"]
        return configuration
    }

    /// A controller on the inert stand-ins. `installedModels` are on disk, `stalledDownloads` have come this far and
    /// go no further, notifications are at `notifications`, and each channel in `failingChannels` has failed once
    /// with its error. Listening is off. A stalled download starts at once unless `startsStalledDownloads` is false.
    static func controller(
        configuration: AppConfiguration = DemoFixtures.settingsConfiguration,
        installedModels: Set<WhisperModel> = [],
        stalledDownloads: [WhisperModel: Double] = [:],
        notifications: PermissionStatus = .granted,
        failingChannels: [ChannelKind: any Error] = [:],
        capabilities: EngineCapabilities = SettingsFixtures.capabilities,
        startsStalledDownloads: Bool = true
    ) async -> ListeningController {
        var dependencies = RuntimeDependencies.inert()
        dependencies.models = FakeModels(installed: installedModels, stalled: stalledDownloads)
        dependencies.permissions = FakePermissions(notifications: notifications)
        dependencies.channels = failingChannels.map { FailingChannel(kind: $0.key, error: $0.value) }
        dependencies.capabilities = { capabilities }

        var configuration = configuration
        configuration.hasCompletedOnboarding = true
        configuration.listening.startOnLaunch = false
        let controller = ListeningController(dependencies: dependencies)
        await controller.update { $0 = configuration }
        await controller.bootstrap()
        if startsStalledDownloads {
            for model in stalledDownloads.keys {
                Task { try? await controller.downloadModel(model) }
            }
        }
        for kind in failingChannels.keys {
            try? await controller.testAlert(kind)
        }
        return controller
    }
}

/// Models that are installed, and downloads that report some progress and then wait until they are cancelled.
struct FakeModels: ModelProviding {
    let installed: Set<WhisperModel>
    let stalled: [WhisperModel: Double]

    func isInstalled(_ model: WhisperModel) async -> Bool {
        installed.contains(model)
    }

    func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let fraction = stalled[model] else { return }
        progress(fraction)
        try await Task.sleep(for: .seconds(3600))
    }

    func delete(_ model: WhisperModel) async throws {}
}

/// Every permission allowed, except notifications, which are at `notifications`.
struct FakePermissions: PermissionsProviding {
    let notifications: PermissionStatus

    func snapshot() async -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: notifications)
    }

    func request(_ kind: PermissionKind) async -> Bool { true }
}

/// A channel that never delivers.
struct FailingChannel: AlertChannel {
    let kind: ChannelKind
    let error: any Error

    func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        throw error
    }
}
