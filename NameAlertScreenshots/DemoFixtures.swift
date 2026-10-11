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

    /// Five mentions for the History renders, newest first: the first and second have an excerpt, one was heard as
    /// "Bhala", one on the microphone and the oldest four days ago.
    static var historyHits: [Hit] {
        let heard = Hit(
            ruleID: nameRule.id, ruleName: nameRule.name, term: "Bala", matchedText: "Bhala",
            context: "…thanks Bhala, that really helps. Next up is the design review for…",
            timestamp: today(9, 15), source: .microphone, engine: .appleSpeechTranscriber, segmentID: "s3")
        let standUp = Hit(
            ruleID: standupRule.id, ruleName: standupRule.name, term: "stand-up", matchedText: "stand up",
            context: "…let's move the stand up to the afternoon so the east coast team can join…",
            timestamp: daysAgo(1, 17, 12), source: .both, engine: .appleSpeechTranscriber, segmentID: "s4")
        let lastWeek = Hit(
            ruleID: nameRule.id, ruleName: nameRule.name, term: "Balakumar", matchedText: "Bala Kumar",
            context: "…as Bala Kumar mentioned last week the migration is on track…",
            timestamp: daysAgo(4, 14, 3), source: .systemAudio, engine: .whisperLight, segmentID: "s5")
        var first = hit(
            nameRule, "Bala", "okay, before we wrap up, can Bala share the screen with the latest numbers",
            at: today(10, 32))
        first.excerpt =
            "okay so that covers the roadmap for the quarter. Before we wrap up I want to hear from the design team first, then, uh, can Bala share the screen with the latest numbers"
        var second = hit(
            standupRule, "standup", "quick reminder that the standup moves to ten thirty tomorrow because of the",
            at: today(9, 58))
        second.excerpt =
            "great. One more thing, the notes from yesterday are in the shared doc. Quick reminder that the standup moves to ten thirty tomorrow because of the offsite"
        return [first, second, heard, standUp, lastWeek]
    }

    /// A stretch of a meeting, about 1 200 characters, for the live transcript renders. The rules in `configuration`
    /// listen for "Bala" and "standup".
    static let longTranscript =
        "okay so that covers the roadmap for the quarter. Before we wrap up I want to hear from the design team first. "
        + "Priya, you had a question about the new onboarding flow? Yes, I wanted to check whether we are still planning "
        + "to ship it before the end of the month, because the copy is not final. We are, but the copy can slip a few "
        + "days. Okay, good. Then let's talk about the standup, it moves to ten thirty tomorrow because of the offsite. "
        + "Great. One more thing, can Bala share the screen with the latest numbers? Sure, give me a second to pull "
        + "them up. While he does that, a quick reminder that the standup notes are in the shared doc. Thanks Bala, "
        + "that really helps. Next up is the design review for the settings screens, and after that we can open it up "
        + "for questions about the launch plan."

    /// What the controller keeps of `longTranscript`: its last words, from the start of a word, at most 300 characters.
    static var liveWindow: String {
        let tail = String(longTranscript.suffix(300))
        guard let space = tail.firstIndex(of: " ") else { return tail }
        return String(tail[tail.index(after: space)...])
    }

    /// Today at `hour`:`minute`.
    static func today(_ hour: Int, _ minute: Int) -> Date {
        daysAgo(0, hour, minute)
    }

    /// `days` days before today, at `hour`:`minute`.
    static func daysAgo(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? Date()
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
