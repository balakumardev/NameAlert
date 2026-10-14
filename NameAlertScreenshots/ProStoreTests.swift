import AppKit
import Foundation
import NameAlertCore
import NameAlertRuntime
import StoreKit
import StoreKitTest
import Testing

@testable import ScreenshotHost

/// A store that sells Pro, on a StoreKit test session of `Pro.storekit` and a defaults domain of its own. StoreKit testing
/// serves products only to an app installed for development: the ad hoc signed ScreenshotHost is one.
@MainActor
private final class StoreHarness {
    let session: SKTestSession
    let suite: String
    let defaults: UserDefaults
    let store: ProStore
    /// Every `access` the store reported, in order.
    private(set) var changes: [ProAccess] = []
    /// What StoreKit anchors a purchase to. The test host has no window of its own, and a purchase without one fails
    /// ("Could not find a UI anchor"); in the app the Buy button's window is the anchor. With `disableDialogs` nothing
    /// is drawn in it, and it sits far off screen.
    private let window: NSWindow

    init(cached: ProAccessRecord? = nil, isEnforced: Bool = true, askToBuy: Bool = false) async throws {
        // Made before the store, so that it serves the products from the first read.
        let session = try SKTestSession(contentsOf: RenderHarness.repositoryRoot.appendingPathComponent("Pro.storekit"))
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.askToBuyEnabled = askToBuy
        // What an earlier test bought can outlive clearTransactions() for a moment: start from nothing bought.
        var leftover = await StoreKit.Transaction.latest(for: ProProduct.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while leftover != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            leftover = await StoreKit.Transaction.latest(for: ProProduct.id)
        }
        try #require(leftover == nil, "a purchase from an earlier test is still in the test session")
        let suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ScratchError.noSuite }
        let cache = ProAccessCache(defaults: defaults)
        if let cached { cache.save(cached) }
        self.session = session
        self.suite = suite
        self.defaults = defaults
        store = ProStore(isEnforced: isEnforced, cache: cache)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 240), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
    }

    /// Buys Pro in the app, the way the Buy button does: through the store, confirmed in a window.
    func buy() async {
        let window = window
        await store.purchase(using: { product in
            guard #available(macOS 15.2, *) else { return try await product.purchase() }
            return try await product.purchase(confirmIn: window)
        })
    }

    func start() {
        store.start { [weak self] access in self?.changes.append(access) }
    }

    /// Starts the store and waits until it has read the purchases and loaded the product.
    func startAndWait() async -> Bool {
        start()
        return await pollUntil(timeout: .seconds(15)) {
            self.store.status != .checking && self.store.productState == .loaded
        }
    }

    var cached: ProAccessRecord? { ProAccessCache(defaults: defaults).load() }

    /// The test session's newest transaction of Pro.
    func latestTransaction() throws -> SKTestTransaction {
        try #require(session.allTransactions().last { $0.productIdentifier == ProProduct.id })
    }

    func finish() {
        store.stop()
        window.close()
        session.clearTransactions()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Reads the purchases again until `condition` holds, every 50 ms for at most `timeout`. Returns whether it held.
@MainActor
private func refreshUntil(
    _ store: ProStore, timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        await store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

@Suite("Pro purchases", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ProStoreTests {
    @Test("The product loads from Pro.storekit with its App Store price, and nothing is owned")
    func loadsTheProduct() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        #expect(h.store.product?.id == ProProduct.id)
        #expect(h.store.displayPrice == "$4.99")
        #expect(h.store.product?.isFamilyShareable == false, "Family Sharing is off")
        #expect(h.store.status == .free)
        #expect(h.store.access == .free)
        #expect(h.changes.isEmpty, "Free at launch and Free after the read is no change")
    }

    @Test("Buying unlocks Pro at once, remembers it and finishes the transaction")
    func buyingUnlocks() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        await h.buy()
        #expect(h.store.status == .pro)
        #expect(h.store.access == .pro)
        #expect(h.store.purchaseState == .idle)
        #expect(h.changes == [.pro])
        #expect(h.cached?.access == .pro)
        var unfinished = 0
        for await _ in StoreKit.Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0)
    }

    @Test("A purchase made outside the app, as on another Mac, arrives through Transaction.updates")
    func purchaseElsewhere() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        try await h.session.buyProduct(identifier: ProProduct.id)
        #expect(await pollUntil(timeout: .seconds(10)) { h.store.access == .pro })
        #expect(h.changes == [.pro])
    }

    @Test("A refund turns Pro off without a relaunch")
    func refund() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        await h.buy()
        #expect(h.store.access == .pro)
        let transaction = try h.latestTransaction()
        try h.session.refundTransaction(identifier: transaction.identifier)
        #expect(await pollUntil(timeout: .seconds(10)) { h.store.access == .free })
        #expect(h.store.status == .free)
        #expect(h.changes == [.pro, .free])
        #expect(h.cached?.access == .free)
    }

    @Test("Ask to Buy waits for approval, then unlocks")
    func askToBuyApproved() async throws {
        let h = try await StoreHarness(askToBuy: true)
        defer { h.finish() }
        #expect(await h.startAndWait())
        await h.buy()
        #expect(h.store.purchaseState == .pending)
        #expect(h.store.access == .free)
        let pending = try h.latestTransaction()
        try h.session.approveAskToBuyTransaction(identifier: pending.identifier)
        #expect(await pollUntil(timeout: .seconds(10)) { h.store.access == .pro })
        #expect(h.store.purchaseState == .idle, "the waiting note goes once Pro is on")
    }

    @Test("Ask to Buy that is not approved leaves Pro off, and the waiting note stays")
    func askToBuyUnanswered() async throws {
        let h = try await StoreHarness(askToBuy: true)
        defer { h.finish() }
        #expect(await h.startAndWait())
        #expect(h.store.access == .free, "nothing is bought at the start")
        await h.buy()
        #expect(h.store.purchaseState == .pending)
        // StoreKit testing (Xcode 27) turns a declined Ask to Buy into a verified, unrevoked purchase for StoreKit 2
        // (Transaction.latest(for:), then currentEntitlements), though its own record says it failed; the App Store
        // makes no transaction for a decline. So no decline is driven here: no answer comes, as after a decline.
        try await Task.sleep(for: .seconds(1))
        await h.store.refresh()
        #expect(h.store.access == .free)
        #expect(h.store.purchaseState == .pending)
        #expect(h.changes.isEmpty)
    }

    @Test("A price that does not load says so, and Try Again loads it")
    func priceDoesNotLoad() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        try await h.session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        h.start()
        #expect(await pollUntil(timeout: .seconds(15)) { h.store.productState == .failed })
        #expect(h.store.displayPrice == nil)
        try await h.session.setSimulatedError(nil, forAPI: .loadProducts)
        await h.store.loadProduct()
        #expect(h.store.productState == .loaded)
        #expect(h.store.displayPrice == "$4.99")
    }

    @Test("Restore says what it found, and a closed sign-in is not an error")
    func restore() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        await h.store.restore(using: {})
        #expect(h.store.restoreState == .nothingFound)
        try await h.session.buyProduct(identifier: ProProduct.id)
        // The purchase made elsewhere reaches the store through Transaction.updates; a read made in the same moment
        // may not have it yet.
        #expect(await pollUntil(timeout: .seconds(10)) { h.store.access == .pro })
        await h.store.restore(using: {})
        #expect(h.store.restoreState == .restored)
        #expect(h.store.access == .pro)
        await h.store.restore(using: { throw StoreKitError.userCancelled })
        #expect(h.store.restoreState == .idle)
        await h.store.restore(using: { throw StoreKitError.networkError(URLError(.notConnectedToInternet)) })
        guard case .failed = h.store.restoreState else {
            Issue.record("A failed restore should say so, not \(h.store.restoreState)")
            return
        }
    }

    @Test("Until StoreKit answers, the last verified answer counts; then StoreKit's does")
    func launchAccess() async throws {
        let h = try await StoreHarness(cached: ProAccessRecord(access: .pro, verifiedAt: .distantPast))
        defer { h.finish() }
        #expect(h.store.status == .checking)
        #expect(h.store.access == .pro, "a Pro owner has Pro from the first moment")
        #expect(await h.startAndWait())
        #expect(h.store.access == .free, "this test session owns nothing")
        #expect(h.changes == [.free])
        #expect(h.cached?.access == .free)
    }

    @Test("A build that cannot sell has everything on, ignores what is cached and touches no StoreKit")
    func notSold() async throws {
        let h = try await StoreHarness(cached: ProAccessRecord(access: .free, verifiedAt: .now), isEnforced: false)
        defer { h.finish() }
        h.start()
        await h.store.refresh()
        await h.store.loadProduct()
        await h.store.purchase()
        await h.store.restore(using: { Issue.record("a build that cannot sell must not restore") })
        #expect(h.store.status == .notSold)
        #expect(h.store.access == .pro)
        #expect(h.store.product == nil)
        #expect(h.store.productState == .idle)
        #expect(h.changes.isEmpty)
    }

    @Test("Buying and a refund reach the listening controller through startPurchases")
    func purchasesReachTheController() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        let controller = DemoFixtures.controller(.off, proAccess: .free)
        let environment = AppEnvironment(controller: controller, router: WindowRouter(), store: h.store)
        environment.startPurchases()
        #expect(await pollUntil(timeout: .seconds(15)) { h.store.status != .checking && h.store.productState == .loaded })
        #expect(controller.proAccess == .free)
        await h.buy()
        #expect(await pollUntil(timeout: .seconds(10)) { controller.proAccess == .pro })
        let transaction = try h.latestTransaction()
        try h.session.refundTransaction(identifier: transaction.identifier)
        #expect(await pollUntil(timeout: .seconds(10)) { controller.proAccess == .free })
    }

    @Test("A transaction StoreKit handed over counts before a read has it, and a refund is never undone")
    func handedOverTransactions() {
        let bought = ProTransaction(productID: ProProduct.id, isRevoked: false)
        let refunded = ProTransaction(productID: ProProduct.id, isRevoked: true)
        #expect(ProStore.merge([:], [7: bought]) == [7: bought], "a read that has not caught up")
        #expect(ProStore.merge([7: bought], [7: refunded]) == [7: refunded], "a refund handed over")
        #expect(ProStore.merge([7: refunded], [7: bought]) == [7: refunded], "a read that has not caught up with a refund")
        #expect(ProStore.merge([7: refunded], [8: bought]) == [7: refunded, 8: bought], "bought again")
    }

    @Test("Once a read has a purchase, the reads decide: an Apple Account that owns nothing is Free")
    func readsDecideOnceTheyHaveThePurchase() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        await h.buy()
        #expect(h.store.access == .pro)
        #expect(await refreshUntil(h.store) { h.store.handedOver.isEmpty }, "a read has the purchase now")
        // Another Apple Account signs in to the App Store, one that owns nothing.
        h.session.clearTransactions()
        #expect(await refreshUntil(h.store) { h.store.access == .free })
        #expect(h.cached?.access == .free)
    }

    @Test("A handed-over purchase is dropped once a read has it; a refund stays")
    func handedOverPurchasesAreDroppedOnceRead() {
        let bought = ProTransaction(productID: ProProduct.id, isRevoked: false)
        let refunded = ProTransaction(productID: ProProduct.id, isRevoked: true)
        #expect(ProStore.stillHandedOver([7: bought], after: [:]) == [7: bought], "the read has not caught up")
        #expect(ProStore.stillHandedOver([7: bought], after: [7: bought]).isEmpty, "from now on the reads decide")
        #expect(ProStore.stillHandedOver([7: refunded], after: [7: bought]) == [7: refunded], "a refund stays")
        #expect(ProStore.stillHandedOver([7: bought, 8: refunded], after: [7: bought]) == [8: refunded])
    }

    @Test("A purchase the App Store cannot verify unlocks nothing, and Restore says so")
    func unverifiedPurchase() async throws {
        let h = try await StoreHarness()
        defer { h.finish() }
        #expect(await h.startAndWait())
        try await h.session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        try await h.session.buyProduct(identifier: ProProduct.id)
        // StoreKit has the purchase once its newest transaction can be read, unverified as it is.
        let deadline = ContinuousClock.now + .seconds(10)
        while await StoreKit.Transaction.latest(for: ProProduct.id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await h.store.restore(using: {})
        #expect(h.store.access == .free)
        #expect(h.store.restoreState == .failed(ProCopy.unverifiedRestore))
        try await h.session.setSimulatedError(nil, forAPI: .verification)
    }

    @Test("A closed App Store sheet is not a failure")
    func cancellation() {
        #expect(ProStore.isCancellation(StoreKitError.userCancelled))
        #expect(ProStore.isCancellation(CancellationError()))
        #expect(!ProStore.isCancellation(StoreKitError.networkError(URLError(.timedOut))))
    }
}
