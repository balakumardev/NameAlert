import Foundation
import NameAlertCore
import Testing

@Suite("ConfigurationCoding")
struct ConfigurationCodingTests {
    // MARK: Helpers

    private func decode(_ json: String) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
    }

    /// A configuration where every field differs from its default, so a round trip proves each one is stored.
    private func customizedConfiguration() -> AppConfiguration {
        var config = AppConfiguration()
        config.hasCompletedOnboarding = true
        config.listening.source = .both
        config.listening.mode = .duringCalls
        config.listening.startOnLaunch = false
        config.speech.engine = .localModel
        config.speech.localModelSize = .balanced
        config.speech.localeIdentifier = "de-DE"
        config.rules = [
            Rule(
                name: "Bala", terms: ["Bala", "Balakumar"], sensitivity: .loose,
                channels: Set(ChannelKind.allCases), cooldownSeconds: 45, isEnabled: false
            ),
        ]
        config.channels.sound.soundName = "Hero"
        config.channels.sound.volume = 0.3
        config.channels.notification.includeContext = false
        config.channels.persistentAlarm.soundName = "Funk"
        config.channels.persistentAlarm.autoStopSeconds = 300
        config.channels.ntfy.server = "https://ntfy.example.org"
        config.channels.ntfy.topic = "team-a"
        config.channels.ntfy.priority = .urgent
        config.channels.telegramCall.user = "@bala"
        config.channels.telegramCall.messageTemplate = "Heard {keyword}"
        config.channels.telegramCall.voice = "en-GB-Standard-A"
        config.channels.webhook.url = "https://example.com/hook"
        config.channels.webhook.headerNames = ["X-Token", "X-Team"]
        config.globalCooldownSeconds = 12.5
        config.history.isEnabled = false
        config.general.launchAtLogin = true
        return config
    }

    // MARK: Defaults and round trips

    @Test func defaultsMatchSpec() {
        let config = AppConfiguration()
        #expect(AppConfiguration.currentSchemaVersion == 1)
        #expect(config.schemaVersion == 1)
        #expect(config.hasCompletedOnboarding == false)
        #expect(config.rules.isEmpty)
        #expect(config.listening.source == .systemAudio)
        #expect(config.listening.mode == .always)
        #expect(config.listening.startOnLaunch == true)
        #expect(config.speech.engine == .automatic)
        #expect(config.speech.localModelSize == .light)
        #expect(config.speech.localeIdentifier == nil)
        #expect(config.globalCooldownSeconds == 3)
        #expect(config.channels.sound.soundName == "Glass")
        #expect(config.channels.sound.volume == 0.8)
        #expect(config.channels.notification.includeContext == true)
        #expect(config.channels.persistentAlarm.soundName == "Sosumi")
        #expect(config.channels.persistentAlarm.autoStopSeconds == 120)
        #expect(PersistentAlarmSettings.autoStopChoices == [30, 60, 120, 300])
        #expect(config.channels.ntfy.server == "https://ntfy.sh")
        #expect(config.channels.ntfy.topic == "")
        #expect(config.channels.ntfy.priority == .high)
        #expect(config.channels.telegramCall.user == "")
        #expect(config.channels.telegramCall.messageTemplate == "NameAlert heard {keyword}: {context}")
        #expect(config.channels.telegramCall.voice == "en-US-Standard-B")
        #expect(config.channels.webhook.url == "")
        #expect(config.channels.webhook.headerNames.isEmpty)
        #expect(config.history.isEnabled == true)
        #expect(config.general.launchAtLogin == false)
    }

    @Test func roundTrip() throws {
        let config = customizedConfiguration()
        #expect(config != AppConfiguration())
        #expect(ChannelKind.allCases.count == 7)
        #expect(config.rules[0].channels.count == 7)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        #expect(try decode("{}") == AppConfiguration())
    }

    // MARK: Tolerant decoding

    @Test func partialRuleGetsDefaults() throws {
        let json = #"{"rules":[{"name":"x","terms":["a"]}]}"#
        let config = try decode(json)
        #expect(config.rules.count == 1)
        let rule = try #require(config.rules.first)
        #expect(rule.name == "x")
        #expect(rule.terms == ["a"])
        #expect(rule.sensitivity == .balanced)
        #expect(rule.channels == [.sound, .notification])
        #expect(rule.cooldownSeconds == 10)
        #expect(rule.isEnabled)
        // A missing id is generated per decode, not a shared constant.
        #expect(try decode(json).rules[0].id != rule.id)
    }

    @Test func unknownValuesFallBackPerField() throws {
        let json = #"""
        {"listening":{"source":"radio","mode":"duringCalls"},
         "rules":[{"name":"x","terms":["a"],"channels":["sound","sms"],"sensitivity":"ultra"}]}
        """#
        let config = try decode(json)
        #expect(config.listening.source == .systemAudio)
        #expect(config.listening.mode == .duringCalls)
        #expect(config.rules.count == 1)
        let rule = try #require(config.rules.first)
        #expect(rule.channels == [.sound])
        #expect(rule.sensitivity == .balanced)
        #expect(rule.name == "x")
        #expect(rule.terms == ["a"])
    }

    @Test func wrongTypedValuesFallBackToDefaults() throws {
        let json = #"""
        {"listening": 5,
         "speech": {"engine": 7, "localeIdentifier": null, "localModelSize": "balanced"},
         "channels": {"sound": {"soundName": "Hero", "volume": "loud"},
                      "ntfy": [],
                      "webhook": {"headerNames": "X-Token", "url": "https://example.com/h"}},
         "globalCooldownSeconds": "fast",
         "history": null,
         "rules": [{"id": "not-a-uuid", "name": "x", "terms": ["a"], "sensitivity": 3, "channels": "sound",
                    "isEnabled": "yes", "cooldownSeconds": "soon"}]}
        """#
        let config = try decode(json)
        #expect(config.listening == ListeningSettings())
        #expect(config.speech.engine == .automatic)
        #expect(config.speech.localeIdentifier == nil)
        #expect(config.speech.localModelSize == .balanced)
        #expect(config.channels.sound.soundName == "Hero")
        #expect(config.channels.sound.volume == 0.8)
        #expect(config.channels.ntfy == NtfySettings())
        #expect(config.channels.webhook.headerNames.isEmpty)
        #expect(config.channels.webhook.url == "https://example.com/h")
        #expect(config.globalCooldownSeconds == 3)
        #expect(config.history == HistorySettings())
        #expect(config.rules.count == 1)
        // Apart from name and terms, a rule's fields are all tolerant: the rule survives with defaults.
        let rule = try #require(config.rules.first)
        #expect(rule.name == "x")
        #expect(rule.terms == ["a"])
        #expect(rule.sensitivity == .balanced)
        #expect(rule.channels == [.sound, .notification])
        #expect(rule.isEnabled)
        #expect(rule.cooldownSeconds == 10)
    }

    @Test func badRuleElementIsSkipped() throws {
        // One unreadable element must not take the user's other rules down with it.
        let json = #"{"rules":[{"name":"a","terms":["x"]},null,42,{"terms":["y"]},{"name":"b","terms":["z"]}]}"#
        let config = try decode(json)
        #expect(config.rules.map(\.name) == ["a", "b"])
        #expect(config.rules.map(\.terms) == [["x"], ["z"]])
    }

    @Test func ruleWithoutUsableNameOrTermsIsSkipped() throws {
        // A rule is only worth keeping with a name and its terms; every other kind of damage leaves it unusable.
        let unusable = [
            #"{"name":3,"terms":["a"]}"#,       // name is not a string
            #"{"name":null,"terms":["a"]}"#,
            #"{"name":"a","terms":"a"}"#,       // terms is not an array
            #"{"name":"a","terms":["x",5]}"#,
            #"{"name":"a"}"#,
            "{}", "[]", #""rule""#, "true",
        ]
        let json = #"{"rules":[\#(unusable.joined(separator: ",")),{"name":"kept","terms":["k"]}]}"#
        let config = try decode(json)
        #expect(config.rules.map(\.name) == ["kept"])
    }

    @Test func rulesFieldThatIsNotAnArrayIsIgnored() throws {
        // Nothing to salvage from the rules themselves, but the rest of the file still loads.
        for json in [#"{"rules":"oops"}"#, #"{"rules":null}"#, #"{"rules":{"name":"a","terms":["x"]}}"#] {
            #expect(try decode(json).rules.isEmpty, "\(json)")
        }
        let config = try decode(#"{"rules":"oops","listening":{"source":"microphone"}}"#)
        #expect(config.listening.source == .microphone)
    }

    @Test func emptyChannelListIsKept() throws {
        // A present array wins over the default: unticking every channel stays unticked.
        let none = try decode(#"{"rules":[{"name":"x","terms":["a"],"channels":[]}]}"#)
        #expect(none.rules[0].channels.isEmpty)
        let onlyUnknown = try decode(#"{"rules":[{"name":"x","terms":["a"],"channels":["sms"]}]}"#)
        #expect(onlyUnknown.rules[0].channels.isEmpty)
    }

    @Test func storeCanDetectNewerOrUnreadableFiles() throws {
        // ConfigStore backs a file up when the version is newer or the document cannot be read at all.
        #expect(try decode(#"{"schemaVersion": 7}"#).schemaVersion == 7)
        #expect(throws: DecodingError.self) { try decode("[1, 2]") }
        #expect(throws: DecodingError.self) { try decode("not json") }
    }

    // MARK: Clamping

    @Test func cooldownsAreClamped() throws {
        let json = #"""
        {"globalCooldownSeconds": 99,
         "rules": [{"name": "low", "terms": ["a"], "cooldownSeconds": 0.5},
                   {"name": "high", "terms": ["b"], "cooldownSeconds": 5000}]}
        """#
        let config = try decode(json)
        #expect(config.rules[0].cooldownSeconds == 2)
        #expect(config.rules[1].cooldownSeconds == 600)
        #expect(Rule(name: "n", terms: ["a"], cooldownSeconds: 1).cooldownSeconds == 2)
        #expect(config.globalCooldownSeconds == 30)

        // Assignment is clamped too, and in-range values pass through untouched.
        var rule = Rule(name: "n", terms: ["a"])
        #expect(Rule.cooldownRange == 2...600)
        rule.cooldownSeconds = 9_999
        #expect(rule.cooldownSeconds == 600)
        rule.cooldownSeconds = -3
        #expect(rule.cooldownSeconds == 2)
        rule.cooldownSeconds = 45
        #expect(rule.cooldownSeconds == 45)
        rule.cooldownSeconds = .nan
        #expect(Rule.cooldownRange.contains(rule.cooldownSeconds))

        var global = AppConfiguration()
        global.globalCooldownSeconds = 99
        #expect(global.globalCooldownSeconds == 30)
        global.globalCooldownSeconds = -1
        #expect(global.globalCooldownSeconds == 0)
        global.globalCooldownSeconds = 7.5
        #expect(global.globalCooldownSeconds == 7.5)
        global.globalCooldownSeconds = .nan
        #expect((0.0...30.0).contains(global.globalCooldownSeconds))
    }

    // MARK: Channel settings

    @Test func isConfiguredRules() {
        var settings = ChannelSettings()

        for kind in [ChannelKind.sound, .notification, .persistentAlarm, .screenFlash] {
            #expect(settings.isConfigured(kind), "\(kind) needs no setup")
        }
        // Channels that need setup start unconfigured.
        #expect(!settings.isConfigured(.ntfy))
        #expect(!settings.isConfigured(.telegramCall))
        #expect(!settings.isConfigured(.webhook))

        for (topic, expected) in [("", false), ("  ", false), ("team-a", true)] {
            settings.ntfy.topic = topic
            #expect(settings.isConfigured(.ntfy) == expected, "ntfy topic \(topic.debugDescription)")
        }

        for (user, expected) in [("", false), ("   ", false), ("@bala", true)] {
            settings.telegramCall.user = user
            #expect(settings.isConfigured(.telegramCall) == expected, "telegram user \(user.debugDescription)")
        }

        let urls = [
            ("", false),
            ("ftp://x", false),
            ("https://", false),
            ("not a url", false),
            ("https://example.com/h", true),
            ("http://localhost:8080/x", true),
            ("  https://example.com/h\n", true),
        ]
        for (url, expected) in urls {
            settings.webhook.url = url
            #expect(settings.isConfigured(.webhook) == expected, "webhook url \(url.debugDescription)")
        }
    }

    @Test func systemSoundNamesAreTheFourteenMacOSSounds() {
        #expect(SystemSounds.names == [
            "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
            "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ])
        for name in SystemSounds.names {
            #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"), "\(name)")
        }
        let defaults = AppConfiguration().channels
        #expect(SystemSounds.names.contains(defaults.sound.soundName))
        #expect(SystemSounds.names.contains(defaults.persistentAlarm.soundName))
    }

    // MARK: Pipeline value types and paths

    @Test func chunkRMS() {
        let chunk = AudioChunk(samples: [0.5, -0.5, 0.5, -0.5], sequence: 0)
        #expect(abs(chunk.rms - 0.5) < 1e-6)
        #expect(AudioChunk(samples: [], sequence: 1).rms == 0)
        #expect(AudioChunk.sampleRate == 16_000)
        #expect(AudioChunk.samplesPerChunk == 1_600)
    }

    @Test func hitRoundTrip() throws {
        let hit = Hit(
            ruleID: UUID(), ruleName: "Bala", term: "Bala", matchedText: "bala", context: "hey bala, lunch?",
            timestamp: Date(timeIntervalSinceReferenceDate: 781_692_800.25), source: .microphone,
            engine: .whisperLight, segmentID: "seg-1"
        )
        let data = try JSONEncoder().encode(hit)
        #expect(try JSONDecoder().decode(Hit.self, from: data) == hit)
    }

    @Test func appPaths() {
        #expect(AppPaths.configFile.lastPathComponent == "config.json")
        #expect(AppPaths.configFile.deletingLastPathComponent().lastPathComponent == "NameAlert")
        #expect(AppPaths.modelsDirectory.lastPathComponent == "Models")
        #expect(AppPaths.historyFile.lastPathComponent == "history.json")
        #expect(AppPaths.historyFile.deletingLastPathComponent().lastPathComponent == "NameAlert")
        #expect(AppPaths.applicationSupport.lastPathComponent == "NameAlert")
    }
}
