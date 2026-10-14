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

    @Test("The Pro pane is shown only where Pro is sold; elsewhere Settings falls back to General")
    func proPaneOnlyWhereItIsSold() {
        #expect(SettingsView.shown(.pro, showsPro: true) == .pro)
        #expect(SettingsView.shown(.pro, showsPro: false) == .general)
        #expect(SettingsView.shown(.alerts, showsPro: false) == .alerts)
    }

    @Test("No words of the purchase name a price; the price comes from the App Store")
    func noPriceInTheWords() {
        let words =
            [
                ProCopy.tagline, ProCopy.freeKeeps, ProCopy.oneTime, ProCopy.restoreHint,
                ProCopy.checking, ProCopy.loadingPrice, ProCopy.priceDidNotLoad, ProCopy.pending, ProCopy.owned,
                ProCopy.restored, ProCopy.nothingFound, ProCopy.unverifiedPurchase,
                ProCopy.ruleLimitTitle, ProCopy.ruleLimitMessage, ProCopy.channelMessage, ProCopy.ruleHeldBack,
                ProCopy.channelSectionNote, ProCopy.popoverRuleLimit, ProCopy.webhookIsPro,
            ] + ProCopy.proAdds
        for text in words {
            #expect(text.range(of: #"[$€£¥]\s?[0-9]"#, options: .regularExpression) == nil, "“\(text)”")
        }
        #expect(ProCopy.buyTitle(price: "$4.99") == "Buy Pro for $4.99")
    }

    @Test("No source file of the app types a price")
    func noPriceInTheSources() throws {
        let root = RenderHarness.repositoryRoot.appendingPathComponent("NameAlert", isDirectory: true)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.range(of: #"\$[0-9]+\.[0-9]{2}"#, options: .regularExpression) == nil, "\(file.lastPathComponent)")
        }
    }

    @Test("The words take the free limit from the policy, and the app's name from the bundle")
    func limitAndName() {
        let limit = "\(ProPolicy.freeRuleLimit)"
        #expect(ProCopy.proAdds[0].contains(limit))
        #expect(ProCopy.ruleLimitMessage.contains(limit))
        #expect(ProCopy.popoverRuleLimit.contains(limit))
        #expect(ProCopy.title == "\(AppInfo.displayName) Pro")
    }

    @Test("The sheet says what was asked for")
    func reasons() {
        #expect(ProUpsellReason.ruleLimit.title == "Add more rules with Pro")
        #expect(ProUpsellReason.channel(.webhook).title == "Webhook is part of Pro")
        #expect(ProUpsellReason.channel(.ntfy).message == ProCopy.channelMessage)
    }

    @Test("Terms of Use is Apple's standard license")
    func terms() {
        #expect(AboutLinks.terms.absoluteString == "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    }
}
