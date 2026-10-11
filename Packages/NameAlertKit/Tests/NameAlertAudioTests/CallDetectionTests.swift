import Foundation
@testable import NameAlertAudio
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let ownPID: Int32 = 100
private let ownBundleID = "dev.balakumar.namealert"

/// `seconds` after `t0`.
private func after(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func makeLogic() -> CallDetectionLogic {
    CallDetectionLogic(ownPID: ownPID, ownBundleID: ownBundleID)
}

/// A process that is recording from the microphone.
private func recording(_ pid: Int32, _ bundleID: String?) -> AudioProcessSnapshot {
    AudioProcessSnapshot(pid: pid, bundleID: bundleID, isRunningInput: true)
}

private let zoom = [recording(200, "us.zoom.xos")]
private let chrome = [recording(400, "com.google.Chrome.helper")]

@Suite("CallDetection")
struct CallDetectionTests {
    // MARK: What counts as a call

    @Test func nothingIsInactive() {
        var logic = makeLogic()
        #expect(logic.update(processes: [], now: t0) == .inactive)
    }

    @Test func zoomActivatesImmediately() {
        var logic = makeLogic()
        #expect(logic.update(processes: zoom, now: t0) == .active(["us.zoom.xos"]))
    }

    @Test func ownAndDaemonsIgnored() {
        var logic = makeLogic()
        let processes = [
            recording(ownPID, "com.example.somethingelse"),  // our process, whatever it calls itself
            recording(300, ownBundleID),  // our bundle ID, from another process
            recording(301, "com.apple.corespeechd"),  // a daemon that listens all day
        ]
        #expect(logic.update(processes: processes, now: t0) == .inactive)
    }

    /// Core Audio reports a bundle ID in whatever case the app spells it, so IDs are compared without regard to case.
    @Test func ownBundleIDMatchesWithoutRegardToCase() {
        var logic = makeLogic()
        #expect(logic.update(processes: [recording(300, ownBundleID.uppercased())], now: t0) == .inactive)
    }

    @Test(arguments: ["COM.APPLE.CORESPEECHD", "com.apple.siri", "Com.Apple.VoiceOver"])
    func ignoredDaemonsMatchWithoutRegardToCase(bundleID: String) {
        var logic = makeLogic()
        #expect(logic.update(processes: [recording(301, bundleID)], now: t0) == .inactive)
    }

    @Test func onlyProcessesThatAreRecordingCount() {
        var logic = makeLogic()
        let playingOnly = [AudioProcessSnapshot(pid: 200, bundleID: "us.zoom.xos", isRunningInput: false)]
        #expect(logic.update(processes: playingOnly, now: t0) == .inactive)
    }

    @Test func nilBundleCounts() {
        var logic = makeLogic()
        #expect(logic.update(processes: [recording(55, nil)], now: t0) == .active(["pid:55"]))
    }

    @Test func anEmptyBundleIDIsTreatedAsNone() {
        var logic = makeLogic()
        #expect(logic.update(processes: [recording(55, "")], now: t0) == .active(["pid:55"]))
    }

    @Test func severalProcessesOfOneAppAreOneEntry() {
        var logic = makeLogic()
        let processes = [recording(200, "us.zoom.xos"), recording(201, "us.zoom.xos"), recording(55, nil)]
        #expect(logic.update(processes: processes, now: t0) == .active(["us.zoom.xos", "pid:55"]))
    }

    @Test func theIgnoredDaemonsMatchTheSpec() {
        #expect(
            CallDetectionLogic.ignoredBundleIDs == [
                "com.apple.corespeechd", "com.apple.CoreSpeech", "com.apple.speech.recognitionserver",
                "com.apple.SpeechRecognitionCore", "com.apple.assistantd", "com.apple.Siri", "com.apple.VoiceOver",
                "com.apple.voicebankingd", "com.apple.accessibility.heard", "com.apple.audioaccessoryd",
                "com.apple.replayd",
            ])
    }

    /// The system's screen-recording daemon records for other apps and is never a call itself.
    @Test func theScreenRecordingDaemonIsIgnored() {
        var logic = makeLogic()
        #expect(logic.update(processes: [recording(302, "com.apple.replayd")], now: t0) == .inactive)
    }

    // MARK: Browsers

    @Test func theBrowsersAreTheSpecsEightAndWebKit() {
        #expect(
            CallDetectionLogic.browserBundleIDPrefixes == [
                "com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.mozilla.firefox",
                "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
                "com.vivaldi.Vivaldi",
            ])
    }

    /// Safari records in WebKit's own helper processes, not under `com.apple.Safari`.
    @Test(arguments: ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"])
    func webKitHelpersNeedTheBrowserDelay(bundleID: String) {
        var logic = makeLogic()
        let helper = [recording(500, bundleID)]
        #expect(logic.update(processes: helper, now: t0) == .inactive)
        #expect(logic.update(processes: helper, now: after(2)) == .inactive)
        #expect(logic.update(processes: helper, now: after(3)) == .active([bundleID]))
    }

    /// Arc's helper processes spell the name in lower case (`company.thebrowser.browser.helper`), unlike the app's own
    /// `company.thebrowser.Browser`, so the prefixes match without regard to case.
    @Test(arguments: ["company.thebrowser.browser.helper", "COM.GOOGLE.CHROME.HELPER"])
    func browserHelpersNeedTheDelayWhateverTheirCase(bundleID: String) {
        var logic = makeLogic()
        let helper = [recording(500, bundleID)]
        #expect(logic.update(processes: helper, now: t0) == .inactive)
        #expect(logic.update(processes: helper, now: after(2)) == .inactive)
        #expect(logic.update(processes: helper, now: after(3)) == .active([bundleID]))
    }

    @Test func browserNeedsThreeSeconds() {
        var logic = makeLogic()
        #expect(logic.update(processes: chrome, now: t0) == .inactive)
        #expect(logic.update(processes: chrome, now: after(2)) == .inactive)
        #expect(logic.update(processes: chrome, now: after(3)) == .active(["com.google.Chrome.helper"]))
    }

    @Test(arguments: CallDetectionLogic.browserBundleIDPrefixes)
    func everyBrowserAndItsHelpersNeedTheDelay(prefix: String) {
        for bundleID in [prefix, prefix + ".helper.Renderer"] {
            var logic = makeLogic()
            let browser = [recording(400, bundleID)]
            #expect(logic.update(processes: browser, now: t0) == .inactive, "\(bundleID) at once")
            #expect(logic.update(processes: browser, now: after(3)) == .active([bundleID]), "\(bundleID) after 3 s")
        }
    }

    @Test func aBrowserThatDropsOutStartsItsDelayAgain() {
        var logic = makeLogic()
        #expect(logic.update(processes: chrome, now: t0) == .inactive)
        #expect(logic.update(processes: [], now: after(2)) == .inactive)  // let go of the microphone
        #expect(logic.update(processes: chrome, now: after(2.5)) == .inactive)  // 3 s since t0, but not since now
        #expect(logic.update(processes: chrome, now: after(5)) == .inactive)  // 2.5 s
        #expect(logic.update(processes: chrome, now: after(5.5)) == .active(["com.google.Chrome.helper"]))
    }

    @Test func aBrowserDoesNotHoldBackOtherApps() {
        var logic = makeLogic()
        let both = zoom + chrome
        #expect(logic.update(processes: both, now: t0) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: both, now: after(3)) == .active(["us.zoom.xos", "com.google.Chrome.helper"]))
    }

    // MARK: Grace

    @Test func graceKeepsActive() {
        var logic = makeLogic()
        #expect(logic.update(processes: zoom, now: t0) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(7)) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(8.1)) == .inactive)
    }

    @Test func aCallEndsEightSecondsAfterTheLastTimeItWasSeen() {
        var logic = makeLogic()
        _ = logic.update(processes: zoom, now: t0)
        _ = logic.update(processes: zoom, now: after(5))  // still there: the eight seconds count from here
        #expect(logic.update(processes: [], now: after(12.999)) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(13)) == .inactive)
    }

    @Test func aCallThatComesBackInsideTheGraceNeverEnded() {
        var logic = makeLogic()
        _ = logic.update(processes: zoom, now: t0)
        #expect(logic.update(processes: [], now: after(6)) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: zoom, now: after(7)) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(14)) == .active(["us.zoom.xos"]))  // 7 s after the last sighting
        #expect(logic.update(processes: [], now: after(15)) == .inactive)
    }

    @Test func clockSteppingBackDoesNotHoldACallOpen() {
        var logic = makeLogic()
        _ = logic.update(processes: zoom, now: after(1_000))
        // The clock is set back by about 17 minutes. The call must not last until it catches up again.
        #expect(logic.update(processes: [], now: t0) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(7.9)) == .active(["us.zoom.xos"]))
        #expect(logic.update(processes: [], now: after(8)) == .inactive)
    }

    // MARK: Reading the real process list

    /// Reads the real Core Audio process list. It needs no permission, but it depends on what the Mac is doing, so it
    /// only runs when asked to: `NAMEALERT_INTEGRATION=1 swift test …`.
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["NAMEALERT_INTEGRATION"] == "1",
            "Set NAMEALERT_INTEGRATION=1 to read the real audio process list."),
        .enabled(if: CallDetector.isSupported, "Needs macOS 14.2 or later."))
    func liveSnapshotSmoke() {
        let processes = CallDetector.currentProcesses()
        let named = processes.filter { $0.bundleID?.isEmpty == false }.count
        let recordingNow = processes.filter(\.isRunningInput).count
        print(
            "liveSnapshotSmoke: \(processes.count) audio processes, \(named) with a bundle ID, "
                + "\(recordingNow) recording")
        #expect(!processes.isEmpty)
        #expect(named > 0, "no process reported a bundle ID")
        #expect(processes.allSatisfy { $0.pid > 0 })
    }
}

// MARK: - The stream

/// Hands out one scripted process list per poll, repeating the last one, and counts the polls.
private final class ScriptedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private let script: [[AudioProcessSnapshot]]
    private var polls = 0

    init(_ script: [[AudioProcessSnapshot]]) {
        self.script = script
    }

    func next() -> [AudioProcessSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let list = script[min(polls, script.count - 1)]
        polls += 1
        return list
    }

    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return polls
    }
}

private func makeDetector(_ script: ScriptedProcesses) -> CallDetector {
    // No grace, so that a call that is gone is reported as soon as it is seen to be gone.
    CallDetector(
        pollInterval: .milliseconds(5), ownPID: ownPID, ownBundleID: ownBundleID, grace: 0,
        reading: { ProcessListReading(processes: script.next()) })
}

@Suite("CallDetection stream", .timeLimit(.minutes(1)))
struct CallDetectionStreamTests {
    @Test func theFirstStateIsYieldedAndThenOnlyChanges() async {
        let script = ScriptedProcesses([[], [], zoom, zoom, zoom, []])
        var seen: [CallState] = []
        for await state in makeDetector(script).states() {
            seen.append(state)
            if seen.count == 3 { break }
        }
        #expect(seen == [.inactive, .active(["us.zoom.xos"]), .inactive])
    }

    @Test func everyStreamStartsFromScratch() async {
        let script = ScriptedProcesses([zoom])
        let detector = makeDetector(script)
        for _ in 1...2 {
            var first: CallState?
            for await state in detector.states() {
                first = state
                break
            }
            #expect(first == .active(["us.zoom.xos"]))
        }
    }

    @Test func cancellingTheConsumerStopsPolling() async throws {
        let script = ScriptedProcesses([[]])
        let consumer = Task {
            for await _ in makeDetector(script).states() {}
        }
        for _ in 1...400 where script.pollCount < 3 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(script.pollCount >= 3, "polling never started")

        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(100))  // a poll that was already under way may still finish
        let settled = script.pollCount
        try await Task.sleep(for: .milliseconds(150))  // thirty more polls, if it were still going

        #expect(script.pollCount == settled)
    }
}

// MARK: - The log

/// What the detector tells the log is worked out here, so that it can be tested without reading the log. An entry holds
/// counts and a status, never which app is recording.
@Suite("CallDetection log")
struct CallDetectionLogTests {
    private let unreadable: OSStatus = -50

    @Test func theStartSaysHowManyProcessesThereAreAndHowManyRecordAndOnlyOnce() {
        var logbook = ProcessListLogbook()
        let processes = [
            recording(200, "us.zoom.xos"),
            AudioProcessSnapshot(pid: 201, bundleID: "com.example.player", isRunningInput: false),
            recording(202, nil),
        ]
        // Four process objects, one of which could not be identified.
        let reading = ProcessListReading(processes: processes, objectCount: 4)
        #expect(logbook.entries(for: reading) == [.started(processObjects: 4, recordingInput: 2)])
        #expect(logbook.entries(for: reading).isEmpty)
    }

    @Test func withoutAnObjectCountTheProcessesAreTheCount() {
        var logbook = ProcessListLogbook()
        let reading = ProcessListReading(processes: zoom + chrome)
        #expect(logbook.entries(for: reading) == [.started(processObjects: 2, recordingInput: 2)])
    }

    @Test func aListThatCannotBeReadIsReportedOnceForEachReasonUntilItReadsAgain() {
        var logbook = ProcessListLogbook()
        let failed = ProcessListReading(processes: [], failure: unreadable)
        // The start is reported as well, with nothing counted.
        #expect(logbook.entries(for: failed) == [.started(processObjects: 0, recordingInput: 0), .unreadable(-50)])
        #expect(logbook.entries(for: failed).isEmpty)
        #expect(logbook.entries(for: failed).isEmpty)

        // Another reason is news.
        #expect(logbook.entries(for: ProcessListReading(processes: [], failure: -1)) == [.unreadable(-1)])

        // Once the list reads again, the next failure is reported afresh.
        #expect(logbook.entries(for: ProcessListReading(processes: zoom)).isEmpty)
        #expect(logbook.entries(for: failed) == [.unreadable(-50)])
    }
}
