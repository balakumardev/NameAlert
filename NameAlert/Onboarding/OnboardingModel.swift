import Foundation
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import Observation

/// What first-time setup has chosen so far, and where it is.
///
/// The choices live here until a step is left; leaving it saves them in the settings (the audio source, then the rule),
/// so the next step already works with them: the permissions the source needs, the words the test listens for.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable, Sendable {
        case welcome, source, permissions, name, engine, finish

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// What VoiceOver says the step is.
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .source: "What to listen to"
            case .permissions: "Permissions"
            case .name: "Your name"
            case .engine: "Speech engine"
            case .finish: "All set"
            }
        }
    }

    /// The name of the rule that setup creates, or updates when it is there already.
    nonisolated static let ruleName = "My name"

    /// The ways of being alerted that setup offers. The others need an address or an account: they are set up later,
    /// in Settings.
    static let offeredChannels: [ChannelKind] = [.sound, .notification, .persistentAlarm, .screenFlash]

    var step: Step

    // The audio source.
    var source: AudioSourceKind
    var onlyDuringCalls: Bool

    // The rule.
    var name: String
    var variants: [String]
    var sensitivity: Sensitivity
    var channels: Set<ChannelKind>

    /// Screen Recording was not allowed at some point during setup, so that if it is now, listening may need a
    /// relaunch to see it.
    var screenRecordingWasOff = false

    // The speech engine and the test.
    /// The engine the settings pick on this Mac; `nil` until it has been asked.
    var resolution: EngineResolution?
    /// The words the test heard, once it did.
    var heard: String?
    /// When the test began listening: mentions older than this are not its own.
    var testStartedAt: Date?
    /// Whether the test is what turned listening on, so that going back (or closing setup) turns it off again.
    var testStartedListening = false

    /// Setup is over, by finishing or by being put off: nothing is undone when its window goes.
    private(set) var isFinished = false
    private var isAdvancing = false

    /// How long after a move the next one is ignored, so that a double click on Continue (or Back) moves one step.
    var lockout: Duration = .milliseconds(350)
    private var lastMove: ContinuousClock.Instant?

    /// `configuration` is what the choices start from: what is saved already, so that running setup again shows it.
    init(configuration: AppConfiguration, step: Step = .welcome) {
        self.step = step
        source = configuration.listening.source
        onlyDuringCalls = configuration.listening.mode == .duringCalls
        let rule = configuration.rules.first { $0.name == Self.ruleName }
        let terms = rule?.terms ?? []
        name = terms.first ?? ""
        variants = Array(terms.dropFirst())
        sensitivity = rule?.sensitivity ?? .balanced
        channels = rule?.channels ?? [.sound, .notification]
    }

    // MARK: The rule

    /// The name as it will be saved: trimmed, with single spaces. Empty when nothing was typed.
    var trimmedName: String {
        PopoverActions.keyword(from: name) ?? ""
    }

    /// The words the rule listens for: the name, then the variants, without repeats (ignoring case).
    var terms: [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for text in [name] + variants {
            guard let term = PopoverActions.keyword(from: text), seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }

    /// The rule to save. `existing` is the rule setup made before (it keeps its identity, its cooldown and any alert
    /// the setup does not offer); without one, a new rule.
    func rule(replacing existing: Rule?) -> Rule {
        var rule = existing ?? Rule(name: Self.ruleName, terms: [])
        rule.name = Self.ruleName
        rule.terms = terms
        rule.sensitivity = sensitivity
        rule.channels = channels
        rule.isEnabled = true
        return rule
    }

    /// Turns one of the offered ways of being alerted on or off.
    func setChannel(_ kind: ChannelKind, isOn: Bool) {
        if isOn { channels.insert(kind) } else { channels.remove(kind) }
    }

    // MARK: Moving

    /// Whether "Continue" is on for the step. `required` are the permissions listening needs.
    ///
    /// The speech engine step is never held up: when the engine is not ready (the local model cannot be downloaded
    /// because the Mac is offline, say) there is nothing to test, and when it is, the test may never hear the name.
    /// Listening tries again once setup is done, and says what is missing if it still cannot.
    func canContinue(permissions: PermissionsSnapshot, required: [PermissionKind]) -> Bool {
        switch step {
        case .welcome, .source, .engine, .finish: true
        case .permissions: required.allSatisfy { permissions[$0] == .granted }
        case .name: !trimmedName.isEmpty
        }
    }

    /// What the button that goes on says. On the engine step it says what going on means until the test has heard the
    /// name: "Continue without testing".
    var continueTitle: String {
        step == .engine && heard == nil ? Self.continueWithoutTesting : "Continue"
    }

    static let continueWithoutTesting = "Continue without testing"

    /// Saves the choices of the step that is left, and goes to the next one. A second call while the first is still
    /// saving, or just after a move, does nothing, so a double click does not skip a step.
    func advance(using controller: ListeningController, supportsCalls: Bool) async {
        guard canMove, let next = Step(rawValue: step.rawValue + 1) else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        switch step {
        case .source: await saveSource(to: controller, supportsCalls: supportsCalls)
        case .permissions: OnboardingResume.clear()
        case .name: await saveRule(to: controller)
        case .welcome, .engine, .finish: break
        }
        move(to: next)
    }

    /// Goes back a step. Leaving the test turns listening off again, if the test turned it on.
    func goBack(using controller: ListeningController) async {
        guard canMove, let previous = Step(rawValue: step.rawValue - 1) else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        if step == .engine { await stopTest(using: controller) }
        move(to: previous)
    }

    /// Whether a move is wanted now: not while another is being made, nor right after one.
    private var canMove: Bool {
        guard !isAdvancing else { return false }
        guard let lastMove else { return true }
        return ContinuousClock.now - lastMove >= lockout
    }

    private func move(to new: Step) {
        step = new
        lastMove = .now
    }

    /// "Set up later": setup counts as done, with no rule. Nothing starts listening, and the "Start listening when the
    /// app opens" setting goes off, so the next launch does not try either (there is nothing to listen for yet).
    func putOff(using controller: ListeningController) async {
        isFinished = true
        OnboardingResume.clear()
        await controller.update { configuration in
            configuration.hasCompletedOnboarding = true
            configuration.listening.startOnLaunch = false
        }
    }

    /// "Done": setup is done, and listening starts if the test has not started it.
    func finish(using controller: ListeningController) async {
        isFinished = true
        OnboardingResume.clear()
        await controller.completeOnboarding()
    }

    /// Turns listening off if the test turned it on, and forgets what the test heard.
    func stopTest(using controller: ListeningController) async {
        guard testStartedListening else { return }
        testStartedListening = false
        heard = nil
        testStartedAt = nil
        await controller.pause()
    }

    // MARK: Saving

    func saveSource(to controller: ListeningController, supportsCalls: Bool) async {
        let source = source
        let mode: ListeningMode = onlyDuringCalls ? .duringCalls : .always
        await controller.update { configuration in
            configuration.listening.source = source
            // Where calls cannot be told, the choice is not offered, and the saved one is left as it is.
            if supportsCalls { configuration.listening.mode = mode }
        }
    }

    func saveRule(to controller: ListeningController) async {
        let existing = controller.configuration.rules.first { $0.name == Self.ruleName }
        let rule = rule(replacing: existing)
        await controller.update { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                configuration.rules[index] = rule
            } else {
                configuration.rules.insert(rule, at: 0)
            }
        }
    }

    // MARK: The test

    /// The words the test heard: the first mention of the setup's rule since the test began, as it was heard.
    static func heardWords(in hits: [Hit], ruleID: UUID?, since start: Date?) -> String? {
        guard let ruleID, let start else { return nil }
        guard let hit = hits.first(where: { $0.ruleID == ruleID && $0.timestamp >= start }) else { return nil }
        return HistoryTable.heard(by: hit)
    }

    /// Notes a mention the test may have been waiting for.
    func noteHits(_ hits: [Hit], ruleID: UUID?) {
        guard heard == nil else { return }
        heard = Self.heardWords(in: hits, ruleID: ruleID, since: testStartedAt)
    }
}

// MARK: - Picking up where setup was

/// Allowing Screen Recording usually ends with macOS asking the app to quit and open again. When setup was at the
/// permissions step then, it starts there again instead of at the welcome.
enum OnboardingResume {
    static let key = "onboarding.resumeAtPermissions"

    /// Remembers that setup is at the permissions step, about to be interrupted.
    static func mark(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// The step setup starts at: the permissions if it was left there, else the welcome. Does not forget the mark.
    static func startStep(_ defaults: UserDefaults = .standard) -> OnboardingModel.Step {
        defaults.bool(forKey: key) ? .permissions : .welcome
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
