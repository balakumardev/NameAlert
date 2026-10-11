import Foundation

public struct ListeningSettings: Codable, Sendable, Equatable {
    public var source: AudioSourceKind = .systemAudio
    public var mode: ListeningMode = .always
    public var startOnLaunch = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &source, forKey: .source)
        container.decodeTolerantly(into: &mode, forKey: .mode)
        container.decodeTolerantly(into: &startOnLaunch, forKey: .startOnLaunch)
    }
}

public struct SpeechSettings: Codable, Sendable, Equatable {
    public var engine: EnginePreference = .automatic
    public var localModelSize: LocalModelSize = .light
    /// `nil` means the system locale.
    public var localeIdentifier: String? = nil

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &engine, forKey: .engine)
        container.decodeTolerantly(into: &localModelSize, forKey: .localModelSize)
        if let identifier = try? container.decodeIfPresent(String.self, forKey: .localeIdentifier) {
            localeIdentifier = identifier
        }
    }
}

public struct HistorySettings: Codable, Sendable, Equatable {
    public var isEnabled = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &isEnabled, forKey: .isEnabled)
    }
}

public struct GeneralSettings: Codable, Sendable, Equatable {
    public var launchAtLogin = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &launchAtLogin, forKey: .launchAtLogin)
    }
}

/// Everything stored in `config.json`.
///
/// Decoding is field by field: a missing key, a value of the wrong type or an unknown enum value falls back
/// to that field's default and never fails the whole file. Only a document that is not a JSON object throws.
/// `schemaVersion` is kept exactly as read so the store can spot a file written by a newer app.
public struct AppConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    static let globalCooldownRange: ClosedRange<Double> = 0...30

    public var schemaVersion = AppConfiguration.currentSchemaVersion
    public var hasCompletedOnboarding = false
    public var listening = ListeningSettings()
    public var speech = SpeechSettings()
    public var rules: [Rule] = []
    public var channels = ChannelSettings()
    /// Minimum seconds between any two alerts. Always within 0...30.
    public var globalCooldownSeconds = 3.0 {
        didSet { globalCooldownSeconds = globalCooldownSeconds.clamped(to: Self.globalCooldownRange) }
    }
    public var history = HistorySettings()
    public var general = GeneralSettings()

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &schemaVersion, forKey: .schemaVersion)
        container.decodeTolerantly(into: &hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        container.decodeTolerantly(into: &listening, forKey: .listening)
        container.decodeTolerantly(into: &speech, forKey: .speech)
        container.decodeTolerantly(into: &rules, forKey: .rules)
        container.decodeTolerantly(into: &channels, forKey: .channels)
        container.decodeTolerantly(into: &globalCooldownSeconds, forKey: .globalCooldownSeconds)
        container.decodeTolerantly(into: &history, forKey: .history)
        container.decodeTolerantly(into: &general, forKey: .general)
        globalCooldownSeconds = globalCooldownSeconds.clamped(to: Self.globalCooldownRange)  // decoding bypasses didSet too
    }
}
