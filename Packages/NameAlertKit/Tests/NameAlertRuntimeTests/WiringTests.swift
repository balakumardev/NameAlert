import Foundation
import NameAlertAlerts
import NameAlertAudio
import NameAlertCore
@testable import NameAlertRuntime
import NameAlertSpeech
import Testing

@MainActor
@Suite("Wiring", .timeLimit(.minutes(1)))
struct WiringTests {
    @Test func demoKeepsGivenState() async {
        var configuration = AppConfiguration()
        configuration.hasCompletedOnboarding = true
        configuration.rules = [Rule(name: "My name", terms: ["Bala"])]
        let info = ListeningInfo(engine: .appleSpeechTranscriber, source: .systemAudio, localeIdentifier: "en-US")
        let hits = [
            Hit(
                ruleID: configuration.rules[0].id, ruleName: "My name", term: "Bala", matchedText: "Bala",
                context: "…can Bala share the deck…", timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                source: .systemAudio, engine: .appleSpeechTranscriber, segmentID: "s2"),
            Hit(
                ruleID: configuration.rules[0].id, ruleName: "My name", term: "Bala", matchedText: "Bala",
                context: "…thanks Bala…", timestamp: Date(timeIntervalSince1970: 1_759_990_000),
                source: .systemAudio, engine: .appleSpeechTranscriber, segmentID: "s1"),
        ]

        let controller = ListeningController.demo(
            configuration: configuration, state: .listening(info), recentHits: hits,
            liveTranscript: "…can Bala share the deck", level: 0.6)

        #expect(controller.configuration == configuration)
        #expect(controller.state == .listening(info))
        #expect(controller.recentHits == hits)
        #expect(controller.liveTranscript == "…can Bala share the deck")
        #expect(controller.level == 0.6)
        #expect(controller.activeEngine == .appleSpeechTranscriber)
        // Nothing was started, and asking does not change that: it already shows listening, and its configuration is
        // not replaced by one loaded from disk.
        await controller.bootstrap()
        await controller.start()
        #expect(controller.state == .listening(info))
        #expect(controller.configuration == configuration)
    }

    @Test func liveBuildsWithoutStarting() {
        let dependencies = RuntimeDependencies.live(appVersion: "1.0.0", build: "1")
        #expect(dependencies.channels.count == 7)
        #expect(Set(dependencies.channels.map(\.kind)) == Set(ChannelKind.allCases))
        #expect(dependencies.callDetectionSupported == CallDetector.isSupported)
        #expect(dependencies.backoffBase == .seconds(1))
    }

    @Test func inertDependenciesNeverListen() async {
        let controller = ListeningController(dependencies: .inert())
        await controller.start()
        #expect(await waitUntil { controller.state == .preparing(.starting) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.state == .preparing(.starting))  // the inert capture never delivers a chunk
        await controller.pause()
        #expect(controller.state == .off)
    }

    @Test func boxForwardsSnoozeAndFallingBehind() async {
        let controller = ListeningController(dependencies: .inert())
        let box = ControllerBox()
        box.controller = controller
        await box.snooze(minutes: 15)
        guard case .snoozed = controller.state else {
            Issue.record("Expected a snooze, got \(controller.state)")
            return
        }
        box.noteLocalModelFallingBehind()
        #expect(controller.warnings == [.localModelFallingBehind])
        await controller.pause()
    }

    @Test func boxWithoutControllerDoesNothing() async {
        let box = ControllerBox()
        await box.snooze(minutes: 15)
        box.noteLocalModelFallingBehind()
        #expect(box.controller == nil)
    }
}

/// Waits until `condition` holds, for at most 5 s.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}
