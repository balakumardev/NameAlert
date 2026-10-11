import Foundation

/// The sounds every Mac ships in `/System/Library/Sounds`.
public enum SystemSounds {
    public static let names: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}

public struct SoundSettings: Codable, Sendable, Equatable {
    static let volumeRange: ClosedRange<Double> = 0...1

    public var soundName = "Glass"
    /// From 0 (silent) to 1 (full volume). Always within that range.
    public var volume = 0.8 {
        didSet { volume = volume.clamped(to: Self.volumeRange) }
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &soundName, forKey: .soundName)
        container.decodeTolerantly(into: &volume, forKey: .volume)
        volume = volume.clamped(to: Self.volumeRange)  // decoding bypasses didSet too
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
    /// Seconds before the alarm stops by itself. A file can hold any number; reading it gives the closest of
    /// `autoStopChoices`, so the setting always shows as one of the choices.
    public var autoStopSeconds = 120

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        container.decodeTolerantly(into: &soundName, forKey: .soundName)
        container.decodeTolerantly(into: &autoStopSeconds, forKey: .autoStopSeconds)
        autoStopSeconds = Self.nearestAutoStopChoice(to: autoStopSeconds)
    }

    /// The choice closest to `seconds`: the longer one when two are equally close, so that an alarm is not cut short.
    static func nearestAutoStopChoice(to seconds: Int) -> Int {
        guard let shortest = autoStopChoices.min(), let longest = autoStopChoices.max() else { return seconds }
        // Limited first, so that the distances below cannot overflow for a huge number.
        let limited = Swift.min(Swift.max(seconds, shortest), longest)
        return autoStopChoices.min { a, b in
            let (distanceA, distanceB) = (abs(a - limited), abs(b - limited))
            return distanceA != distanceB ? distanceA < distanceB : a > b
        } ?? limited
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
