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
    /// Sound, notification, alarm and screen flash always work. ntfy needs a topic and a usable server, Telegram a user
    /// and the webhook a usable address. An address is usable when it has a host and is `https`, or is plain `http` to a
    /// host on the local network (see `isLocalNetworkHost`): what was heard does not cross the internet unencrypted.
    /// Surrounding whitespace does not count.
    public func isConfigured(_ kind: ChannelKind) -> Bool {
        switch kind {
        case .sound, .notification, .persistentAlarm, .screenFlash: true
        case .ntfy: !Self.trimmed(ntfy.topic).isEmpty && Self.isUsableAddress(ntfy.server)
        case .telegramCall: !Self.trimmed(telegramCall.user).isEmpty
        case .webhook: Self.isUsableAddress(webhook.url)
        }
    }

    /// Whether plain `http` may be used to reach `host`, because it is this Mac or a device on the user's own network:
    ///
    /// - `localhost`;
    /// - a name ending in `.local` (what Macs and many NAS boxes call themselves over Bonjour);
    /// - an IPv4 address in 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16;
    /// - the IPv6 loopback address `::1`, with or without square brackets.
    ///
    /// Case does not matter. Nothing else counts, and a name is only judged by what it says, not by where it points.
    /// `host` is the host alone, without scheme, port or path. The app's `NSAllowsLocalNetworking` setting is what lets
    /// such requests through App Transport Security.
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        var name = trimmed(host).lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())  // how an IPv6 address stands in a URL
        }
        if name == "localhost" || name == "::1" { return true }
        if name.hasSuffix(".local") { return name.count > ".local".count }
        guard let octets = ipv4Octets(name) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` is an address an alert may be sent to: it has a scheme and a host, and is `https` or is `http`
    /// to a local network host. It is read as a `URL`, the way the webhook channel reads it, so an address that the
    /// channel can call is not turned down here for something like a space in its query.
    private static func isUsableAddress(_ text: String) -> Bool {
        guard let url = URL(string: trimmed(text)), let scheme = url.scheme?.lowercased(),
            let host = url.host(), !host.isEmpty
        else { return false }
        switch scheme {
        case "https": return true
        case "http": return isLocalNetworkHost(host)
        default: return false
        }
    }

    /// The four numbers of `text` when it is an IPv4 address written the usual way: four groups of one to three digits
    /// with no leading zeros (a resolver may read those as octal, so `010.0.0.1` is not `10.0.0.1`), none above 255.
    /// Shorter or stranger spellings (`127.1`, `0x7f.0.0.1`, `2130706433`) are not recognized.
    private static func ipv4Octets(_ text: String) -> [Int]? {
        let groups = text.split(separator: ".", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return nil }
        var octets: [Int] = []
        for group in groups {
            let isDigits = group.utf8.allSatisfy { (0x30...0x39).contains($0) }
            guard isDigits, group.count <= 3, group == "0" || !group.hasPrefix("0"), let value = Int(group), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }
}
