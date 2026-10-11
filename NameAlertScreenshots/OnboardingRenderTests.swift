import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import SwiftUI
import Testing

@testable import ScreenshotHost

/// Setup as it is on a Mac where nothing is set up: no rules, setup not done.
private var freshConfiguration: AppConfiguration {
    var configuration = AppConfiguration()
    configuration.hasCompletedOnboarding = false
    return configuration
}

/// Settings with the rule that setup makes.
private var configurationWithMyName: AppConfiguration {
    var configuration = freshConfiguration
    configuration.rules = [Rule(name: OnboardingModel.ruleName, terms: ["Bala", "Balakumar", "Bala Kumar"])]
    return configuration
}

private let settleTime = Duration.milliseconds(500)

@Suite("Onboarding renders", .serialized)
@MainActor
struct OnboardingRenderTests {
    private func appearance(_ dark: Bool) -> NSAppearance.Name { dark ? .darkAqua : .aqua }
    private func suffix(_ dark: Bool) -> String { dark ? "-dark" : "" }

    /// The model a render starts from: at `step`, with the demo name filled in when `filled`.
    private func model(_ step: OnboardingModel.Step, filled: Bool = false) -> OnboardingModel {
        let model = OnboardingModel(configuration: freshConfiguration, step: step)
        if filled {
            model.name = "Bala"
            model.variants = ["Balakumar", "Bala Kumar"]
        }
        return model
    }

    private func render(
        _ step: OnboardingModel.Step, name: String, dark: Bool, controller: ListeningController,
        model: OnboardingModel? = nil
    ) async throws {
        let view = SettingsRenderFrame {
            OnboardingView(presetModel: model ?? self.model(step))
                .environment(controller)
                .environment(WindowRouter())
        }
        try await RenderHarness.render(
            view, size: OnboardingView.size, name: name + suffix(dark), appearance: appearance(dark),
            afterWaiting: settleTime)
    }

    @Test("1 Welcome renders", arguments: [false, true])
    func welcome(dark: Bool) async throws {
        try await render(
            .welcome, name: "onboarding-1-welcome", dark: dark,
            controller: DemoFixtures.controller(.off, configuration: freshConfiguration))
    }

    @Test("2 What to listen to renders", arguments: [false, true])
    func source(dark: Bool) async throws {
        try await render(
            .source, name: "onboarding-2-source", dark: dark,
            controller: DemoFixtures.controller(.off, configuration: freshConfiguration))
    }

    @Test("2 What to listen to renders with Both chosen")
    func sourceBoth() async throws {
        let setup = model(.source)
        setup.source = .both
        setup.onlyDuringCalls = true
        try await render(
            .source, name: "onboarding-2-source-both", dark: false,
            controller: DemoFixtures.controller(.off, configuration: freshConfiguration), model: setup)
    }

    @Test("3 Permissions render with one denied, one allowed and one not asked yet", arguments: [false, true])
    func permissionsDenied(dark: Bool) async throws {
        var configuration = freshConfiguration
        configuration.listening.source = .both
        let controller = await SettingsFixtures.controller(
            configuration: configuration,
            permissions: PermissionsSnapshot(
                microphone: .denied, screenRecording: .granted, speechRecognition: .granted, notifications: .notDetermined))
        let setup = model(.permissions)
        setup.screenRecordingWasOff = true  // it was turned on while setup was open: a relaunch may be needed
        try await render(
            .permissions, name: "onboarding-3-permissions", dark: dark, controller: controller, model: setup)
    }

    @Test("3 Permissions render before anything is asked, and with everything allowed")
    func permissionsOtherStates() async throws {
        let fresh = await SettingsFixtures.controller(
            configuration: freshConfiguration,
            permissions: PermissionsSnapshot(
                microphone: .notDetermined, screenRecording: .notDetermined, speechRecognition: .notDetermined,
                notifications: .notDetermined))
        try await render(.permissions, name: "onboarding-3-permissions-new", dark: false, controller: fresh)

        let allowed = await SettingsFixtures.controller(
            configuration: freshConfiguration,
            permissions: PermissionsSnapshot(
                microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .granted))
        try await render(.permissions, name: "onboarding-3-permissions-ready", dark: false, controller: allowed)
    }

    @Test("4 Your name renders filled in", arguments: [false, true])
    func name(dark: Bool) async throws {
        try await render(
            .name, name: "onboarding-4-name", dark: dark,
            controller: DemoFixtures.controller(.off, configuration: freshConfiguration),
            model: model(.name, filled: true))
    }

    @Test("4 Your name renders empty, with Continue off, and with other choices")
    func nameVariants() async throws {
        let controller = DemoFixtures.controller(.off, configuration: freshConfiguration)
        try await render(.name, name: "onboarding-4-name-empty", dark: false, controller: controller)

        let other = model(.name, filled: true)
        other.sensitivity = .loose
        other.setChannel(.persistentAlarm, isOn: true)
        other.setChannel(.notification, isOn: false)
        try await render(.name, name: "onboarding-4-name-other", dark: false, controller: controller, model: other)
    }

    @Test("5 Speech engine renders a local model that is being downloaded", arguments: [false, true])
    func engineDownloading(dark: Bool) async throws {
        var configuration = configurationWithMyName
        configuration.speech.engine = .localModel
        let controller = await SettingsFixtures.controller(
            configuration: configuration, stalledDownloads: [.lightEnglish: 0.45])
        try await render(
            .engine, name: "onboarding-5-engine-download", dark: dark, controller: controller,
            model: model(.engine, filled: true))
    }

    @Test("5 Speech engine renders the download not started, and no engine at all")
    func engineOtherStates() async throws {
        var local = configurationWithMyName
        local.speech.engine = .localModel
        let notDownloaded = await SettingsFixtures.controller(configuration: local)
        try await render(
            .engine, name: "onboarding-5-engine-model", dark: false, controller: notDownloaded,
            model: model(.engine, filled: true))

        var appleOnly = configurationWithMyName
        appleOnly.speech.engine = .apple
        let noApple = await SettingsFixtures.controller(
            configuration: appleOnly, capabilities: SettingsFixtures.capabilitiesWithoutApple)
        try await render(
            .engine, name: "onboarding-5-engine-none", dark: false, controller: noApple,
            model: model(.engine, filled: true))
    }

    @Test("5 Speech engine renders the test waiting for the name, and the name heard", arguments: [false, true])
    func engineTest(dark: Bool) async throws {
        let listening = DemoFixtures.controller(
            .listening(DemoFixtures.listeningInfo), transcript: "okay so before we wrap up I think we should ask",
            level: 0.4, configuration: configurationWithMyName)
        try await render(
            .engine, name: "onboarding-5-engine-test", dark: dark, controller: listening,
            model: model(.engine, filled: true))

        let heard = model(.engine, filled: true)
        heard.heard = "Bala"
        try await render(
            .engine, name: "onboarding-5-engine-heard", dark: dark, controller: listening, model: heard)
    }

    @Test("5 Speech engine renders the test starting, and a problem")
    func engineTestStates() async throws {
        let starting = DemoFixtures.controller(
            .preparing(.installingAppleAssets(0.6)), configuration: configurationWithMyName)
        try await render(
            .engine, name: "onboarding-5-engine-preparing", dark: false, controller: starting,
            model: model(.engine, filled: true))

        let denied = DemoFixtures.controller(
            .error(.permissionDenied(.screenRecording)), configuration: configurationWithMyName)
        let problem = model(.engine, filled: true)
        problem.testStartedAt = Date()  // the test has begun, so it is not started again over the error
        try await render(
            .engine, name: "onboarding-5-engine-problem", dark: false, controller: denied, model: problem)
    }

    @Test("6 All set renders", arguments: [false, true])
    func finish(dark: Bool) async throws {
        try await render(
            .finish, name: "onboarding-6-finish", dark: dark,
            controller: DemoFixtures.controller(.listening(DemoFixtures.listeningInfo), configuration: configurationWithMyName))
    }
}

// MARK: - Logic

@Suite("Onboarding logic")
@MainActor
struct OnboardingLogicTests {
    private let allowed = PermissionsSnapshot(
        microphone: .granted, screenRecording: .granted, speechRecognition: .granted, notifications: .granted)

    private func makeController(_ configuration: AppConfiguration = freshConfiguration, state: ListeningState = .off)
        -> ListeningController
    {
        DemoFixtures.controller(state, configuration: configuration)
    }

    // MARK: Words

    @Test("The six steps follow one another and say where they are")
    func steps() {
        #expect(OnboardingModel.Step.allCases == [.welcome, .source, .permissions, .name, .engine, .finish])
        #expect(OnboardingModel.Step.allCases.map(\.title) == [
            "Welcome", "What to listen to", "Permissions", "Your name", "Speech engine", "All set",
        ])
        #expect(StepDots.description(of: .permissions) == "Step 3 of 6, Permissions")
        #expect(OnboardingModel.Step.welcome < .finish)
        #expect(OnboardingView.size == CGSize(width: 600, height: 460))
    }

    @Test("The welcome says what the brief says")
    func welcomeWords() {
        #expect(WelcomeStep.headline == "Hear your name, even when you're not listening.")
        #expect(WelcomeStep.points.map { $0.text } == [
            "Works with calls, videos and the room around you", "Runs entirely on this Mac",
            "You choose how to be alerted",
        ])
        for point in WelcomeStep.points {
            #expect(NSImage(systemSymbolName: point.symbol, accessibilityDescription: nil) != nil, "\(point.symbol)")
        }
    }

    @Test("The source cards say what the brief says, and their symbols exist")
    func sourceWords() {
        #expect(SourceStep.sources == [.systemAudio, .microphone, .both])
        #expect(SourceStep.description(for: .systemAudio) == "Calls, meetings and videos playing on this Mac.")
        #expect(SourceStep.description(for: .microphone) == "People talking in the room.")
        #expect(AudioSourceKind.allCases.map(GeneralSettingsView.title(for:)) == ["System audio", "Microphone", "Both"])
        for source in AudioSourceKind.allCases {
            for symbol in SourceStep.symbols(for: source) {
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }

    @Test("The name step asks what the brief says")
    func nameWords() {
        #expect(NameStep.variantsPrompt == "Nicknames or spellings, e.g. Bala, Balakumar")
        #expect(NameStep.alertQuestion == "How should we alert you?")
        #expect(NameStep.laterNote.contains("set up later in Settings"))
        #expect(OnboardingModel.offeredChannels.map(\.displayName) == [
            "Sound", "Notification", "Alarm until dismissed", "Screen flash",
        ])
    }

    @Test("The finish says where the app lives, and its illustration's symbols exist")
    func finishWords() {
        #expect(FinishStep.headline == "\(AppInfo.displayName) lives in your menu bar.")
        for symbol in ["arrow.up.right", "wifi", "battery.100", "ear.fill"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    // MARK: Choices

    @Test("Setup starts from what is saved: nothing the first time, the rule and the source when run again")
    func startsFromWhatIsSaved() {
        let fresh = OnboardingModel(configuration: freshConfiguration)
        #expect(fresh.step == .welcome)
        #expect(fresh.source == .systemAudio)
        #expect(!fresh.onlyDuringCalls)
        #expect(fresh.name.isEmpty)
        #expect(fresh.variants.isEmpty)
        #expect(fresh.sensitivity == .balanced)
        #expect(fresh.channels == [.sound, .notification])

        var saved = configurationWithMyName
        saved.listening.source = .microphone
        saved.listening.mode = .duringCalls
        saved.rules[0].sensitivity = .loose
        saved.rules[0].channels = [.sound, .ntfy]
        let again = OnboardingModel(configuration: saved)
        #expect(again.source == .microphone)
        #expect(again.onlyDuringCalls)
        #expect(again.name == "Bala")
        #expect(again.variants == ["Balakumar", "Bala Kumar"])
        #expect(again.sensitivity == .loose)
        #expect(again.channels == [.sound, .ntfy])
    }

    @Test("The words of the rule are the name and the nicknames, trimmed and without repeats")
    func ruleWords() {
        let model = OnboardingModel(configuration: freshConfiguration)
        model.name = "  Bala   Kumar "
        model.variants = ["bala kumar", "Balakumar", " ", "BALAKUMAR", "Bala"]
        #expect(model.trimmedName == "Bala Kumar")
        #expect(model.terms == ["Bala Kumar", "Balakumar", "Bala"])
        model.name = "   "
        #expect(model.trimmedName.isEmpty)
        #expect(model.terms == ["bala kumar", "Balakumar", "Bala"])
    }

    @Test("The rule is called My name, on by default for sound and notification, and keeps what it had")
    func theRule() {
        let model = OnboardingModel(configuration: freshConfiguration)
        model.name = "Bala"
        model.variants = ["Balakumar"]
        let new = model.rule(replacing: nil)
        #expect(new.name == "My name")
        #expect(new.terms == ["Bala", "Balakumar"])
        #expect(new.sensitivity == .balanced)
        #expect(new.channels == [.sound, .notification])
        #expect(new.isEnabled)

        // Run again: the rule keeps its identity and cooldown, and an alert the steps do not offer.
        var old = Rule(name: "My name", terms: ["Old"], sensitivity: .exact, channels: [.sound, .webhook], cooldownSeconds: 45)
        old.isEnabled = false
        let again = OnboardingModel(configuration: { var c = freshConfiguration; c.rules = [old]; return c }())
        again.name = "Bala"
        again.variants = []
        again.setChannel(.screenFlash, isOn: true)
        again.setChannel(.sound, isOn: false)
        let updated = again.rule(replacing: old)
        #expect(updated.id == old.id)
        #expect(updated.cooldownSeconds == 45)
        #expect(updated.terms == ["Bala"])
        #expect(updated.channels == [.webhook, .screenFlash])
        #expect(updated.isEnabled)
        #expect(updated.sensitivity == .exact)
    }

    // MARK: Moving

    @Test("Continue is on when the step is valid")
    func canContinue() {
        let model = OnboardingModel(configuration: freshConfiguration)
        let none = PermissionsSnapshot(
            microphone: .notDetermined, screenRecording: .denied, speechRecognition: .notDetermined, notifications: .notDetermined)
        for step in [OnboardingModel.Step.welcome, .source, .finish] {
            model.step = step
            #expect(model.canContinue(permissions: none, required: [.screenRecording], engineIsReady: false), "\(step)")
        }

        model.step = .permissions
        #expect(!model.canContinue(permissions: none, required: [.screenRecording], engineIsReady: false))
        #expect(model.canContinue(permissions: allowed, required: [.screenRecording, .microphone], engineIsReady: false))
        // Only what is required counts: notifications are a recommendation.
        var noNotifications = allowed
        noNotifications.notifications = .denied
        #expect(model.canContinue(permissions: noNotifications, required: [.screenRecording], engineIsReady: false))
        var noMicrophone = allowed
        noMicrophone.microphone = .denied
        #expect(!model.canContinue(permissions: noMicrophone, required: [.screenRecording, .microphone], engineIsReady: false))

        model.step = .name
        #expect(!model.canContinue(permissions: allowed, required: [], engineIsReady: true))
        model.name = "   "
        #expect(!model.canContinue(permissions: allowed, required: [], engineIsReady: true))
        model.name = " Bala "
        #expect(model.canContinue(permissions: allowed, required: [], engineIsReady: false))

        model.step = .engine
        #expect(!model.canContinue(permissions: allowed, required: [], engineIsReady: false))
        #expect(model.canContinue(permissions: allowed, required: [], engineIsReady: true))
    }

    @Test("Leaving the source step saves what to listen to; calls are left alone where they cannot be told")
    func savingTheSource() async {
        let controller = makeController()
        let model = OnboardingModel(configuration: freshConfiguration, step: .source)
        model.source = .both
        model.onlyDuringCalls = true
        await model.advance(using: controller, supportsCalls: true)
        #expect(model.step == .permissions)
        #expect(controller.configuration.listening.source == .both)
        #expect(controller.configuration.listening.mode == .duringCalls)
        // The permissions the next step shows follow the source.
        #expect(controller.requiredPermissions() == [.microphone, .screenRecording])

        let unsupported = makeController()
        let other = OnboardingModel(configuration: freshConfiguration, step: .source)
        other.source = .microphone
        other.onlyDuringCalls = true
        await other.advance(using: unsupported, supportsCalls: false)
        #expect(unsupported.configuration.listening.source == .microphone)
        #expect(unsupported.configuration.listening.mode == .always)
    }

    @Test("Leaving the name step saves the rule once, first in the list, and again in place")
    func savingTheRule() async {
        var configuration = freshConfiguration
        configuration.rules = [Rule(name: "Standup", terms: ["standup"])]
        let controller = makeController(configuration)
        let model = OnboardingModel(configuration: configuration, step: .name)
        model.lockout = .zero
        model.name = "Bala"
        model.variants = ["Balakumar"]
        await model.advance(using: controller, supportsCalls: true)
        #expect(model.step == .engine)
        #expect(controller.configuration.rules.map(\.name) == ["My name", "Standup"])
        #expect(controller.configuration.rules[0].terms == ["Bala", "Balakumar"])
        let id = controller.configuration.rules[0].id

        // Back and forward with another word: the same rule, changed.
        await model.goBack(using: controller)
        #expect(model.step == .name)
        model.variants.append("Bala Kumar")
        await model.advance(using: controller, supportsCalls: true)
        #expect(controller.configuration.rules.map(\.name) == ["My name", "Standup"])
        #expect(controller.configuration.rules[0].id == id)
        #expect(controller.configuration.rules[0].terms == ["Bala", "Balakumar", "Bala Kumar"])
    }

    @Test("A double click on Continue or Back moves one step, and the ends do not move")
    func oneStepAtATime() async {
        let controller = makeController()
        let model = OnboardingModel(configuration: freshConfiguration, step: .source)
        await model.advance(using: controller, supportsCalls: true)
        await model.advance(using: controller, supportsCalls: true)  // the second click of a double click
        #expect(model.step == .permissions)
        await model.goBack(using: controller)  // and straight back: also ignored
        #expect(model.step == .permissions)

        // Once the pause is over, the next click moves again.
        model.lockout = .zero
        await model.goBack(using: controller)
        #expect(model.step == .source)

        let start = OnboardingModel(configuration: freshConfiguration)
        start.lockout = .zero
        await start.goBack(using: controller)
        #expect(start.step == .welcome)
        let end = OnboardingModel(configuration: freshConfiguration, step: .finish)
        end.lockout = .zero
        await end.advance(using: controller, supportsCalls: true)
        #expect(end.step == .finish)

        // Two clicks at once (a save still going on) are one as well.
        let busy = OnboardingModel(configuration: freshConfiguration, step: .source)
        busy.lockout = .zero
        busy.source = .microphone
        async let first: Void = busy.advance(using: controller, supportsCalls: true)
        async let second: Void = busy.advance(using: controller, supportsCalls: true)
        _ = await (first, second)
        #expect(busy.step == .permissions)
    }

    @Test("Going back from the test turns listening off if the test turned it on, and only then")
    func leavingTheTest() async {
        let listening = makeController(state: .listening(DemoFixtures.listeningInfo))
        let started = OnboardingModel(configuration: freshConfiguration, step: .engine)
        started.lockout = .zero
        started.testStartedListening = true
        started.testStartedAt = Date()
        started.heard = "Bala"
        await started.goBack(using: listening)
        #expect(started.step == .name)
        #expect(!started.testStartedListening)
        #expect(started.heard == nil)
        #expect(started.testStartedAt == nil)
        #expect(listening.state == .off)

        // Listening that was on before the test is left on.
        let already = makeController(state: .listening(DemoFixtures.listeningInfo))
        let kept = OnboardingModel(configuration: freshConfiguration, step: .engine)
        kept.lockout = .zero
        kept.testStartedAt = Date()
        await kept.goBack(using: already)
        #expect(already.state == .listening(DemoFixtures.listeningInfo))
    }

    @Test("Set up later finishes setup with no rule, does not start listening, and turns off start at launch")
    func settingUpLater() async {
        let controller = makeController()
        let model = OnboardingModel(configuration: freshConfiguration)
        #expect(!controller.configuration.hasCompletedOnboarding)
        #expect(controller.configuration.listening.startOnLaunch, "On by default, until Set up later turns it off")
        await model.putOff(using: controller)
        #expect(controller.configuration.hasCompletedOnboarding)
        #expect(!controller.configuration.listening.startOnLaunch)
        #expect(controller.configuration.rules.isEmpty)
        #expect(controller.state == .off)
        #expect(model.isFinished)
    }

    @Test("Done finishes setup and starts listening")
    func done() async {
        let controller = makeController(configurationWithMyName)
        let model = OnboardingModel(configuration: configurationWithMyName, step: .finish)
        await model.finish(using: controller)
        #expect(controller.configuration.hasCompletedOnboarding)
        #expect(controller.state != .off, "Listening started: \(controller.state)")
        #expect(model.isFinished)
        await controller.pause()
    }

    // MARK: Picking up where it was

    @Test("Setup starts at the permissions after an interruption there, and not twice")
    func resume() {
        let suite = "onboarding-resume-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(OnboardingResume.startStep(defaults) == .welcome)
        OnboardingResume.mark(defaults)
        #expect(OnboardingResume.startStep(defaults) == .permissions)
        #expect(OnboardingResume.startStep(defaults) == .permissions, "Reading does not forget it")
        OnboardingResume.clear(defaults)
        #expect(OnboardingResume.startStep(defaults) == .welcome)
    }

    @Test("Leaving the permissions step forgets the interruption")
    func leavingThePermissionsForgets() async {
        OnboardingResume.mark()
        defer { OnboardingResume.clear() }
        let model = OnboardingModel(configuration: freshConfiguration, step: .permissions)
        await model.advance(using: makeController(), supportsCalls: true)
        #expect(OnboardingResume.startStep() == .welcome)
    }

    // MARK: Permissions

    @Test("A permission card offers Allow, then System Settings, and says which")
    func permissionCards() {
        #expect(PermissionCard.action(for: .notDetermined, hasAsked: false) == .allow)
        #expect(PermissionCard.action(for: .notDetermined, hasAsked: true) == .openSettings)
        #expect(PermissionCard.action(for: .denied, hasAsked: false) == .openSettings)
        #expect(PermissionCard.action(for: .denied, hasAsked: true) == .openSettings)
        #expect(PermissionCard.action(for: .granted, hasAsked: true) == .none)

        #expect(PermissionCard.pill(for: .granted, hasAsked: false) == .init(text: "Allowed", tone: .good))
        #expect(PermissionCard.pill(for: .denied, hasAsked: false) == .init(text: "Not allowed", tone: .bad))
        #expect(PermissionCard.pill(for: .notDetermined, hasAsked: true) == .init(text: "Not allowed", tone: .bad))
        #expect(PermissionCard.pill(for: .notDetermined, hasAsked: false) == .init(text: "Not asked yet", tone: .neutral))
    }

    @Test("Every permission has a name, a reason that names the app, and a symbol that exists")
    func permissionWords() {
        #expect(PermissionKind.allCases.map(PermissionCard.title(for:)) == [
            "Microphone", "Screen Recording", "Speech Recognition", "Notifications",
        ])
        for kind in PermissionKind.allCases {
            #expect(!PermissionCard.reason(for: kind).isEmpty)
            #expect(NSImage(systemSymbolName: PermissionCard.symbol(for: kind), accessibilityDescription: nil) != nil)
            // The same pane the popover's fixes open.
            #expect(SystemSettingsLink.url(for: kind) != nil)
        }
        #expect(PermissionCard.reason(for: .screenRecording).contains(AppInfo.displayName))
        #expect(PermissionCard.relaunchNote.contains(AppInfo.displayName))
    }

    @Test("Relaunch is offered for Screen Recording once it is allowed after being off, or when capture was refused")
    func relaunchRule() {
        let rule = PermissionsStep.showsRelaunch
        #expect(rule(.screenRecording, .granted, true, false))
        #expect(rule(.screenRecording, .granted, false, true))
        #expect(!rule(.screenRecording, .granted, false, false))
        #expect(!rule(.screenRecording, .notDetermined, true, true))
        #expect(!rule(.microphone, .granted, true, true))
        #expect(PermissionsStep.allAllowed([.microphone, .screenRecording], in: allowed))
        #expect(!PermissionsStep.allAllowed([.microphone], in: PermissionsSnapshot(
            microphone: .denied, screenRecording: .granted, speechRecognition: .granted, notifications: .granted)))
        #expect(PermissionsStep.allAllowed([], in: PermissionsSnapshot(
            microphone: .denied, screenRecording: .denied, speechRecognition: .denied, notifications: .denied)))
    }

    // MARK: The engine and the test

    @Test("The engine step says what the brief says, and when it can start")
    func engineWords() {
        let apple = EngineResolution.engine(.appleSpeechTranscriber, localeIdentifier: "en-US")
        let local = EngineResolution.engine(.whisperLight, localeIdentifier: "en-US")
        #expect(EngineStepLogic.summary(for: apple) == .init(
            name: "Apple Speech (on-device)", reason: "Your Mac has Apple's on-device speech recognition."))
        #expect(EngineStepLogic.summary(for: local) == .init(
            name: "Local model · Light", reason: "This Mac needs a small download for speech recognition."))
        #expect(EngineStepLogic.summary(for: nil).name == "Checking…")
        let none = EngineStepLogic.summary(for: .unavailable(reason: "Not here."))
        #expect(none.isProblem)
        #expect(none.reason.hasPrefix("Not here."))
        #expect(EngineStepLogic.prompt == "Say your name out loud, or play a video that says it.")
        #expect(EngineStepLogic.successMessage(heard: "Bala") == "Got it — heard “Bala”")

        #expect(EngineStepLogic.model(for: apple) == nil)
        #expect(EngineStepLogic.model(for: local) == .lightEnglish)
        #expect(EngineStepLogic.model(for: .engine(.whisperBalanced, localeIdentifier: "de-DE")) == .balancedMultilingual)
        #expect(EngineStepLogic.model(for: .unavailable(reason: "x")) == nil)

        #expect(EngineStepLogic.isReady(apple, installed: []))
        #expect(!EngineStepLogic.isReady(nil, installed: [.lightEnglish, .vad]))
        #expect(!EngineStepLogic.isReady(.unavailable(reason: "x"), installed: [.lightEnglish, .vad]))
        #expect(!EngineStepLogic.isReady(local, installed: []))
        #expect(!EngineStepLogic.isReady(local, installed: [.lightEnglish]), "The speech detector is needed too")
        #expect(!EngineStepLogic.isReady(local, installed: [.vad]))
        #expect(EngineStepLogic.isReady(local, installed: [.lightEnglish, .vad]))
    }

    @Test("The test hears the setup's rule after it began, and what was heard is what it names")
    func heardWords() {
        let rule = Rule(name: "My name", terms: ["Bala"])
        let other = Rule(name: "Standup", terms: ["standup"])
        let start = Date(timeIntervalSince1970: 1_000)
        func hit(_ rule: Rule, _ heard: String, at seconds: Double) -> Hit {
            Hit(
                ruleID: rule.id, ruleName: rule.name, term: rule.terms[0], matchedText: heard, context: "c",
                timestamp: Date(timeIntervalSince1970: seconds), source: .systemAudio, engine: .appleSpeechTranscriber,
                segmentID: "s")
        }
        let hits = [hit(other, "standup", at: 1_030), hit(rule, "Bhala", at: 1_020), hit(rule, "Bala", at: 900)]
        #expect(OnboardingModel.heardWords(in: hits, ruleID: rule.id, since: start) == "Bhala")
        #expect(OnboardingModel.heardWords(in: hits, ruleID: other.id, since: start) == "standup")
        #expect(OnboardingModel.heardWords(in: [hit(rule, "Bala", at: 900)], ruleID: rule.id, since: start) == nil)
        #expect(OnboardingModel.heardWords(in: hits, ruleID: nil, since: start) == nil)
        #expect(OnboardingModel.heardWords(in: hits, ruleID: rule.id, since: nil) == nil)

        let model = OnboardingModel(configuration: freshConfiguration, step: .engine)
        model.noteHits(hits, ruleID: rule.id)
        #expect(model.heard == nil, "It has not begun")
        model.testStartedAt = start
        model.noteHits(hits, ruleID: rule.id)
        #expect(model.heard == "Bhala")
        model.noteHits([hit(rule, "Bala", at: 1_090)], ruleID: rule.id)
        #expect(model.heard == "Bhala", "The first thing heard stays")

        let saved = configurationWithMyName
        #expect(EngineStep.ruleID(in: saved) == saved.rules[0].id)
        #expect(EngineStep.ruleID(in: freshConfiguration) == nil)
    }

    @Test("The model sizes the engine step offers are the real downloads")
    func downloadSizes() {
        let local = EngineResolution.engine(.whisperLight, localeIdentifier: "en-US")
        #expect(EngineStep.downloadSize(of: .light, resolution: local) == "32 MB")
        #expect(EngineStep.downloadSize(of: .balanced, resolution: local) == "60 MB")
        #expect(EngineStep.downloadSize(of: .light, resolution: nil) == "32 MB")
    }

    // MARK: Size

    @Test("Every step fills the 600 × 460 window exactly, and cannot be made smaller")
    func sizes() {
        for step in OnboardingModel.Step.allCases {
            let setup = OnboardingModel(configuration: freshConfiguration, step: step)
            let view = OnboardingView(presetModel: setup)
                .environment(makeController())
                .environment(WindowRouter())
            let fitting = RenderHarness.fittingSize(of: view, width: nil)
            #expect(fitting == OnboardingView.size, "\(step) asks for \(fitting)")
            let smallest = NSHostingController(rootView: view).sizeThatFits(in: .zero)
            #expect(smallest == OnboardingView.size, "\(step) can shrink to \(smallest)")
        }
    }
}
