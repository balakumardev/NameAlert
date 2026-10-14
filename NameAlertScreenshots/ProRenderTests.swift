import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

/// The Settings window at its minimum size.
private let settingsSize = CGSize(width: 760, height: 540)

/// A store that sells Pro and shows `status`, with nothing read or bought: one state of the purchase, for renders.
@MainActor
func presentedStore(
    _ status: ProStore.Status, price: String? = "$4.99", productState: ProStore.ProductState? = nil,
    purchase: ProStore.PurchaseState = .idle, restore: ProStore.RestoreState = .idle
) -> ProStore {
    let store = ProStore(isEnforced: true, cache: nil)
    store.present(
        status: status, displayPrice: price, productState: productState, purchaseState: purchase, restoreState: restore)
    return store
}

/// Every state of the purchase that Settings → Pro shows.
enum ProScene: String, CaseIterable, Sendable {
    case checking, free, loadingPrice, priceFailed, purchasing, pending, purchaseFailed
    case owned, restored, nothingFound, restoreFailed

    @MainActor var store: ProStore {
        switch self {
        case .checking: presentedStore(.checking, price: nil)
        case .free: presentedStore(.free)
        case .loadingPrice: presentedStore(.free, price: nil, productState: .loading)
        case .priceFailed: presentedStore(.free, price: nil, productState: .failed)
        case .purchasing: presentedStore(.free, purchase: .purchasing)
        case .pending: presentedStore(.free, purchase: .pending)
        case .purchaseFailed:
            presentedStore(.free, purchase: .failed(ProCopy.purchaseFailed(URLError(.notConnectedToInternet))))
        case .owned: presentedStore(.pro, price: nil)
        case .restored: presentedStore(.pro, price: nil, restore: .restored)
        case .nothingFound: presentedStore(.free, restore: .nothingFound)
        case .restoreFailed: presentedStore(.free, restore: .failed(ProCopy.restoreFailed(URLError(.timedOut))))
        }
    }
}

@Suite("Pro renders", .serialized)
@MainActor
struct ProRenderTests {
    @Test("Settings → Pro renders every state of the purchase", arguments: ProScene.allCases)
    func pane(_ scene: ProScene) throws {
        let store = scene.store
        let view = SettingsRenderFrame {
            SettingsView(section: .pro)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration, proAccess: store.access))
                .environment(store)
        }
        try RenderHarness.render(view, size: settingsSize, name: "settings-pro-\(scene.rawValue)")
    }

    @Test("Settings → Pro renders in dark", arguments: [ProScene.free, .owned])
    func paneDark(_ scene: ProScene) throws {
        let store = scene.store
        let view = SettingsRenderFrame {
            SettingsView(section: .pro)
                .environment(DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration, proAccess: store.access))
                .environment(store)
        }
        try RenderHarness.render(view, size: settingsSize, name: "settings-pro-\(scene.rawValue)-dark", appearance: .darkAqua)
    }

    @Test(
        "The sheet where a free limit is reached renders for rules and for each alert that leaves the Mac",
        arguments: [ProUpsellReason.ruleLimit, .channel(.ntfy), .channel(.telegramCall), .channel(.webhook)])
    func sheet(_ reason: ProUpsellReason) throws {
        let name: String =
            switch reason {
            case .ruleLimit: "rules"
            case .channel(let kind): kind.rawValue
            }
        let view = ProUpsellSheet(reason: reason, store: presentedStore(.free))
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
        try RenderHarness.render(view, width: ProUpsellSheet.width, name: "pro-sheet-\(name)")
    }

    @Test("Settings opens on the pane it was asked for, and takes the request")
    func requestedPane() throws {
        let router = WindowRouter()
        router.openSettings(at: .pro)
        _ = router.takePending()
        let view = SettingsRenderFrame {
            SettingsView(section: .general)
                .environment(DemoFixtures.controller(.off))
                .environment(router)
                .environment(presentedStore(.free))
        }
        try RenderHarness.render(view, size: settingsSize, name: "settings-pro-requested")
        #expect(router.requestedSection == nil, "Settings took the request")
    }
}
