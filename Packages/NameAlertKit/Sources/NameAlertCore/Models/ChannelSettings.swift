import Foundation

/// The sounds every Mac ships in `/System/Library/Sounds`.
public enum SystemSounds {
    public static let names: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}

public struct SoundSettings: Codable, Sendable, Equatable {
    public var soundName = "Glass"
    public var volume = 0.8

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &soundName, forKey: .soundName)
        container.decodeTolerantly(into: &volume, forKey: .volume)
    }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    public var includeContext = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &includeContext, forKey: .includeContext)
    }
}

public struct PersistentAlarmSettings: Codable, Sendable, Equatable {
    public static let autoStopChoices = [30, 60, 120, 300]

    public var soundName = "Sosumi"
    public var autoStopSeconds = 120

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &soundName, forKey: .soundName)
        container.decodeTolerantly(into: &autoStopSeconds, forKey: .autoStopSeconds)
    }
}

/// No options in 1.0, so there is nothing to decode.
public struct ScreenFlashSettings: Codable, Sendable, Equatable {
    public init() {}
}

public struct NtfySettings: Codable, Sendable, Equatable {
    public var server = "https://ntfy.sh"
    public var topic = ""
    public var priority: NtfyPriority = .high

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &server, forKey: .server)
        container.decodeTolerantly(into: &topic, forKey: .topic)
        container.decodeTolerantly(into: &priority, forKey: .priority)
    }
}

public struct TelegramCallSettings: Codable, Sendable, Equatable {
    public var user = ""
    public var messageTemplate = "NameAlert heard {keyword}: {context}"
    public var voice = "en-US-Standard-B"

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &user, forKey: .user)
        container.decodeTolerantly(into: &messageTemplate, forKey: .messageTemplate)
        container.decodeTolerantly(into: &voice, forKey: .voice)
    }
}

/// Header *names* live here; their values are secrets and live in the Keychain.
public struct WebhookSettings: Codable, Sendable, Equatable {
    public var url = ""
    public var headerNames: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &url, forKey: .url)
        container.decodeTolerantly(into: &headerNames, forKey: .headerNames)
    }
}

public struct ChannelSettings: Codable, Sendable, Equatable {
    public var sound = SoundSettings()
    public var notification = NotificationSettings()
    public var persistentAlarm = PersistentAlarmSettings()
    public var screenFlash = ScreenFlashSettings()
    public var ntfy = NtfySettings()
    public var telegramCall = TelegramCallSettings()
    public var webhook = WebhookSettings()

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &sound, forKey: .sound)
        container.decodeTolerantly(into: &notification, forKey: .notification)
        container.decodeTolerantly(into: &persistentAlarm, forKey: .persistentAlarm)
        container.decodeTolerantly(into: &screenFlash, forKey: .screenFlash)
        container.decodeTolerantly(into: &ntfy, forKey: .ntfy)
        container.decodeTolerantly(into: &telegramCall, forKey: .telegramCall)
        container.decodeTolerantly(into: &webhook, forKey: .webhook)
    }

    /// Whether `kind` has what it needs to deliver an alert.
    ///
    /// Sound, notification, alarm and screen flash always work. ntfy needs a topic, Telegram a user and the
    /// webhook an http(s) URL. Surrounding whitespace does not count.
    public func isConfigured(_ kind: ChannelKind) -> Bool {
        switch kind {
        case .sound, .notification, .persistentAlarm, .screenFlash: true
        case .ntfy: !Self.trimmed(ntfy.topic).isEmpty
        case .telegramCall: !Self.trimmed(telegramCall.user).isEmpty
        case .webhook: Self.isWebURL(webhook.url)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: trimmed(text)), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && !(url.host() ?? "").isEmpty
    }
}
