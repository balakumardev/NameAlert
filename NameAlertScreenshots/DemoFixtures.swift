import Foundation
import NameAlertCore
import NameAlertRuntime

/// Demo data for renders and screenshots: a set-up configuration, a few mentions, and a demo controller (which runs
/// nothing) for any state.
@MainActor
enum DemoFixtures {
    static let nameRule = Rule(name: "My name", terms: ["Bala"])
    static let standupRule = Rule(name: "Standup", terms: ["standup"])

    /// Three rules that fill the Rules settings: the usual one for a name, one on exact matching with a longer
    /// cooldown, and one that is switched off.
    static var settingsRules: [Rule] {
        [
            Rule(
                name: "My name", terms: ["Bala", "Balakumar", "Bala Kumar"], sensitivity: .balanced,
                channels: [.sound, .notification], cooldownSeconds: 10),
            Rule(
                name: "Standup", terms: ["standup", "stand-up"], sensitivity: .exact,
                channels: [.sound, .persistentAlarm], cooldownSeconds: 45),
            Rule(
                name: "Project Atlas", terms: ["Atlas"], sensitivity: .loose, channels: [.notification],
                cooldownSeconds: 120, isEnabled: false),
        ]
    }

    /// A configuration with `settingsRules`, for the Settings renders.
    static var settingsConfiguration: AppConfiguration {
        var configuration = Self.configuration
        configuration.rules = settingsRules
        return configuration
    }

    static var configuration: AppConfiguration {
        var configuration = AppConfiguration()
        configuration.hasCompletedOnboarding = true
        configuration.rules = [nameRule, standupRule]
        return configuration
    }

    static let listeningInfo = ListeningInfo(engine: .appleSpeechTranscriber, source: .systemAudio, localeIdentifier: "en-US")

    static let transcript =
        "okay so before we wrap up I think we should ask Bala to walk us through the numbers for this quarter"

    /// Three mentions from this morning, newest first.
    static var hits: [Hit] {
        [
            hit(nameRule, "Bala", "okay, before we wrap up, can Bala share the screen with the latest numbers", at: today(10, 32)),
            hit(standupRule, "standup", "quick reminder that the standup moves to ten thirty tomorrow because of the", at: today(9, 58)),
            hit(nameRule, "Bala", "thanks Bala, that really helps. Next up is the design review for", at: today(9, 15)),
        ]
    }

    /// Today at `hour`:`minute`.
    static func today(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func hit(_ rule: Rule, _ term: String, _ context: String, at date: Date) -> Hit {
        Hit(
            ruleID: rule.id, ruleName: rule.name, term: term, matchedText: term, context: "…\(context)…",
            timestamp: date, source: .systemAudio, engine: .appleSpeechTranscriber, segmentID: UUID().uuidString)
    }

    static func controller(
        _ state: ListeningState, hits: [Hit] = [], transcript: String = "", level: Double = 0,
        configuration: AppConfiguration = configuration
    ) -> ListeningController {
        .demo(configuration: configuration, state: state, recentHits: hits, liveTranscript: transcript, level: level)
    }
}
