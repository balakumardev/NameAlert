import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

@Suite("Pro copy and logic")
@MainActor
struct ProLogicTests {
    @Test("Settings can be asked to open on a pane, once")
    func settingsOnAPane() {
        let router = WindowRouter()
        router.openSettings(at: .pro)
        #expect(router.takePending() == .settings)
        #expect(router.takeRequestedSection() == .pro)
        #expect(router.takeRequestedSection() == nil)
    }

    @Test("Tests and renders get a store that sells nothing, with everything on")
    func defaultStoreSellsNothing() {
        let environment = AppEnvironment(controller: DemoFixtures.controller(.off), router: WindowRouter())
        #expect(!environment.store.isEnforced)
        #expect(environment.store.access == .pro)
        #expect(environment.store.status == .notSold)
    }
}
