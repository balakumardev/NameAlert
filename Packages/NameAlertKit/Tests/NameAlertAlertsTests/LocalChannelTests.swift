import CoreGraphics
import Foundation
import NameAlertCore
import Testing
import UserNotifications

@testable import NameAlertAlerts

// MARK: - Helpers

private let ruleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func sampleHit(term: String = "Bala", context: String = "…can Bala share the deck…") -> Hit {
    Hit(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, ruleID: ruleID, ruleName: "My name", term: term,
        matchedText: term, context: context, timestamp: Date(timeIntervalSince1970: 1_760_175_000),
        source: .systemAudio, engine: .appleSpeechTranscriber, segmentID: "s1")
}

private func content(_ term: String = "Bala") -> AlarmContent { AlarmContent(hit: sampleHit(term: term)) }

// MARK: - Tests

/// None of these show a window, play a sound or talk to the notification center: they test the parts that are
/// plain values and rules. (`UNUserNotificationCenter.current()` can crash in a process without an app bundle.)
@Suite("LocalChannels")
struct LocalChannelsTests {
    // MARK: Notification

    @Test func notificationContent() {
        let hit = sampleHit()

        let content = NotificationChannel.makeContent(for: hit, settings: NotificationSettings())
        #expect(content.title == "Heard “Bala”")
        #expect(content.body == "…can Bala share the deck…")
        #expect(content.categoryIdentifier == "HIT")
        #expect(content.threadIdentifier == ruleID.uuidString)
        #expect(content.userInfo["ruleID"] as? String == ruleID.uuidString)
        #expect(content.sound == UNNotificationSound.default)

        var withoutContext = NotificationSettings()
        withoutContext.includeContext = false
        let plain = NotificationChannel.makeContent(for: hit, settings: withoutContext)
        #expect(plain.title == "Heard “Bala”")
        #expect(plain.body == "My name")  // the rule's name, not the words that were heard
        #expect(plain.categoryIdentifier == "HIT")
        #expect(plain.threadIdentifier == ruleID.uuidString)
    }

    @Test func notificationWithNothingHeardAroundTheTermShowsTheRuleName() {
        let content = NotificationChannel.makeContent(for: sampleHit(context: "  \n"), settings: NotificationSettings())
        #expect(content.body == "My name")
    }

    @Test func categoryIDs() {
        #expect(NotificationActions.categoryID == "HIT")
        #expect(NotificationActions.snoozeActionID == "SNOOZE_15")
        #expect(NotificationActions.openHistoryActionID == "OPEN_HISTORY")
    }

    @Test func notificationCategoryOffersSnoozeAndHistory() {
        let category = NotificationActions.makeCategory()

        #expect(category.identifier == "HIT")
        #expect(category.actions.map(\.identifier) == ["SNOOZE_15", "OPEN_HISTORY"])
        #expect(category.actions.map(\.title) == ["Snooze 15 min", "Open History"])
        #expect(category.actions[0].options == [])  // snoozing does not need the app in front
        #expect(category.actions[1].options == [.foreground])  // opening the history does
    }

    @Test func notificationPermissionMapping() {
        #expect(NotificationActions.permissionStatus(for: .authorized) == .granted)
        #expect(NotificationActions.permissionStatus(for: .provisional) == .granted)
        #expect(NotificationActions.permissionStatus(for: .denied) == .denied)
        #expect(NotificationActions.permissionStatus(for: .notDetermined) == .notDetermined)
    }

    // MARK: Factory

    @Test func factoryHasAllKinds() {
        let channels = AlertChannelFactory.makeAll(appVersion: "1.0.0", build: "1", onSnooze: { _ in })

        #expect(Set(channels.map(\.kind)) == Set(ChannelKind.allCases))
        #expect(channels.count == ChannelKind.allCases.count)  // one of each kind, none twice
    }

    @Test func localChannelsReportTheirKind() {
        #expect(SoundChannel().kind == .sound)
        #expect(NotificationChannel().kind == .notification)
        #expect(PersistentAlarmChannel(onSnooze: { _ in }).kind == .persistentAlarm)
        #expect(ScreenFlashChannel().kind == .screenFlash)
    }

    // MARK: Alarm content

    @Test func alarmContentReadsFromTheHit() {
        let content = AlarmContent(hit: sampleHit())

        #expect(content.title == "Heard “Bala”")
        #expect(content.ruleName == "My name")
        #expect(content.context == "…can Bala share the deck…")
    }

    // MARK: Alarm state

    @Test func firstHitOpensTheAlarm() {
        var state = AlarmState()

        let effects = state.present(content(), soundName: "Sosumi", autoStopSeconds: 120)

        #expect(effects == [.open(content()), .startSound("Sosumi"), .armTimer(generation: 1, seconds: 120)])
        #expect(state.isShowing)
    }

    @Test func aNewHitWhileShowingUpdatesTheTextAndRestartsTheTimer() {
        var state = AlarmState()
        _ = state.present(content("Bala"), soundName: "Sosumi", autoStopSeconds: 120)

        let effects = state.present(content("Balakumar"), soundName: "Sosumi", autoStopSeconds: 60)

        // The sound that is looping keeps going: it is not started again.
        #expect(effects == [.update(content("Balakumar")), .armTimer(generation: 2, seconds: 60)])
        #expect(state.content == content("Balakumar"))
    }

    @Test func theTimerOfAnEarlierHitDoesNothing() {
        var state = AlarmState()
        _ = state.present(content("Bala"), soundName: "Sosumi", autoStopSeconds: 120)
        _ = state.present(content("Balakumar"), soundName: "Sosumi", autoStopSeconds: 120)

        #expect(state.timerFired(generation: 1) == [])  // the first hit's timer, set before the second hit
        #expect(state.isShowing)
        #expect(state.timerFired(generation: 2) == [.stopSound, .close])
        #expect(state.isShowing == false)
    }

    @Test func dismissSilencesAndCloses() {
        var state = AlarmState()
        _ = state.present(content(), soundName: "Sosumi", autoStopSeconds: 120)

        #expect(state.dismiss() == [.stopSound, .close])
        #expect(state.isShowing == false)
    }

    @Test func snoozeAsksForFifteenMinutesThenCloses() {
        var state = AlarmState()
        _ = state.present(content(), soundName: "Sosumi", autoStopSeconds: 120)

        #expect(state.snooze(minutes: 15) == [.snooze(minutes: 15), .stopSound, .close])
        #expect(state.isShowing == false)
    }

    @Test func buttonsAndTimerDoNothingWhenNothingIsShowing() {
        var state = AlarmState()
        #expect(state.dismiss() == [])
        #expect(state.snooze(minutes: 15) == [])
        #expect(state.timerFired(generation: 0) == [])

        // Nor does a second press, or a timer that fires after the alarm was dismissed.
        _ = state.present(content(), soundName: "Sosumi", autoStopSeconds: 120)
        #expect(state.dismiss() == [.stopSound, .close])
        #expect(state.dismiss() == [])
        #expect(state.snooze(minutes: 15) == [])
        #expect(state.timerFired(generation: 1) == [])
    }

    @Test func aTimerFromBeforeADismissCannotCloseTheNextAlarm() {
        var state = AlarmState()
        _ = state.present(content("Bala"), soundName: "Sosumi", autoStopSeconds: 120)  // timer of generation 1
        _ = state.dismiss()
        let effects = state.present(content("Ana"), soundName: "Glass", autoStopSeconds: 30)

        guard case .armTimer(let generation, _)? = effects.last else {
            Issue.record("the alarm did not set a timer")
            return
        }
        #expect(effects.first == .open(content("Ana")))
        #expect(effects.contains(.startSound("Glass")))  // a new alarm starts its own sound
        #expect(generation != 1)
        #expect(state.timerFired(generation: 1) == [])  // the old timer is too late
        #expect(state.isShowing)
        #expect(state.timerFired(generation: generation) == [.stopSound, .close])
    }

    @Test func autoStopIsAtLeastOneSecond() {
        var state = AlarmState()
        let effects = state.present(content(), soundName: "Sosumi", autoStopSeconds: 0)
        #expect(effects.last == .armTimer(generation: 1, seconds: 1))
    }

    // MARK: Alarm placement

    @Test func alarmSitsInTheTopRightCornerWithAMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)  // below the menu bar, say
        let origin = AlarmPlacement.origin(for: CGSize(width: 340, height: 160), in: visible)

        #expect(AlarmPlacement.margin == 16)
        #expect(origin == CGPoint(x: 1440 - 340 - 16, y: 875 - 160 - 16))
    }

    @Test func alarmFollowsTheScreenItIsPlacedOn() {
        let visible = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let origin = AlarmPlacement.origin(for: CGSize(width: 340, height: 160), in: visible)

        #expect(origin == CGPoint(x: 3360 - 340 - 16, y: 855 - 160 - 16))
    }

    @Test func alarmDoesNotLeaveASmallScreen() {
        let visible = CGRect(x: 100, y: 50, width: 300, height: 120)
        let origin = AlarmPlacement.origin(for: CGSize(width: 340, height: 160), in: visible)

        #expect(origin == CGPoint(x: 100, y: 50))  // the screen's own corner wins over the margin
    }

    @Test func theAlarmOpensOnTheScreenWithTheMouse() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

        #expect(AlarmPlacement.screenIndex(containing: CGPoint(x: 100, y: 100), in: [main, side]) == 0)
        #expect(AlarmPlacement.screenIndex(containing: CGPoint(x: 2000, y: 500), in: [main, side]) == 1)
        #expect(AlarmPlacement.screenIndex(containing: CGPoint(x: 2000, y: 1080), in: [main, side]) == 1)  // top edge
        #expect(AlarmPlacement.screenIndex(containing: CGPoint(x: -4000, y: 0), in: [main, side]) == nil)
        #expect(AlarmPlacement.screenIndex(containing: .zero, in: []) == nil)
    }

    // MARK: Screen flash

    @Test func flashFadesInAndOutOverSixTenthsOfASecond() {
        let plan = FlashPlan.make(reduceMotion: false)

        #expect(plan == .fade(inSeconds: 0.3, outSeconds: 0.3))
        #expect(abs(plan.totalSeconds - 0.6) < 1e-9)
    }

    @Test func flashIsAStaticBorderForASecondWithReduceMotion() {
        let plan = FlashPlan.make(reduceMotion: true)

        #expect(plan == .hold(seconds: 1))
        #expect(plan.totalSeconds == 1)
    }

    @Test func flashBorderIsEightPoints() {
        #expect(FlashPlan.borderWidth == 8)
    }
}
