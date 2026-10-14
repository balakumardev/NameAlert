import Foundation
import NameAlertCore
import Observation
import StoreKit

/// Sells Pro through the Mac App Store, and says whether this copy of the app has it.
///
/// Only the build that can sell enforces anything (`StoreBuild.isEnforced`: the App Store build, or a Debug run with
/// `-EnforcePro YES`). Every other build is `.notSold`: everything is on, it never makes a StoreKit object and it shows
/// no purchase.
///
/// In the build that sells, `start` makes the app's one `Transaction.updates` listener (purchases on another Mac, Ask to
/// Buy approvals, refunds), finishes what an earlier run left unfinished, reads the purchases and loads the product.
/// Until that first read, `access` is the last verified answer on this Mac (`ProAccessCache`), so a Pro owner has Pro
/// from the first moment; StoreKit answers from its own store on the Mac, offline too. The purchases are read again when
/// the app comes forward, when the Mac wakes, when a purchase screen appears and after a purchase or a restore; a read
/// that started earlier and finishes later is dropped (`RefreshOrder`). A verified transaction is applied, then
/// finished; an unverified one unlocks nothing and is left unfinished.
@MainActor
@Observable
final class ProStore {
    enum Status: Equatable {
        /// A build that cannot sell: everything is on.
        case notSold
        /// StoreKit has not answered yet in this launch.
        case checking
        case free
        case pro
    }

    enum ProductState: Equatable { case idle, loading, loaded, failed }

    enum PurchaseState: Equatable {
        case idle, purchasing
        /// Ask to Buy: waiting for a parent's approval, which arrives through `Transaction.updates`.
        case pending
        case failed(String)
    }

    enum RestoreState: Equatable { case idle, restoring, restored, nothingFound, failed(String) }

    static let shared = ProStore(isEnforced: StoreBuild.isEnforced)

    let isEnforced: Bool
    private(set) var status: Status
    private(set) var product: Product?
    private(set) var productState: ProductState = .idle
    private(set) var purchaseState: PurchaseState = .idle
    private(set) var restoreState: RestoreState = .idle

    private let cache: ProAccessCache?
    private let launchAccess: ProAccess
    private let logger = Log.logger("store")
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var refreshOrder = RefreshOrder()
    /// The verified transactions of Pro StoreKit handed over in this launch (a purchase, an Ask to Buy approval, a refund),
    /// by transaction ID. A read of the purchases can lag a moment behind them, so every read is merged with them. A
    /// purchase is dropped once a read has it (`stillHandedOver`): from then on the reads decide, so an App Store sign-in
    /// to another Apple Account turns Pro off. A refund stays.
    @ObservationIgnored private(set) var handedOver: [UInt64: ProTransaction] = [:]
    @ObservationIgnored private var onAccessChange: (@MainActor (ProAccess) -> Void)?
    /// Set by `present`: a state shown for a render, with nothing read or bought.
    @ObservationIgnored private var isPresented = false
    @ObservationIgnored private var presentedPrice: String?

    /// `cache` keeps the last verified answer; `nil` keeps nothing (renders).
    init(isEnforced: Bool, cache: ProAccessCache? = ProAccessCache()) {
        self.isEnforced = isEnforced
        self.cache = cache
        launchAccess = isEnforced ? ProEntitlement.launchAccess(cached: cache?.load()) : .pro
        status = isEnforced ? .checking : .notSold
    }

    /// What this copy may do now.
    var access: ProAccess {
        switch status {
        case .notSold, .pro: .pro
        case .free: .free
        case .checking: launchAccess
        }
    }

    /// The price as the App Store shows it in this storefront, once the product has loaded.
    var displayPrice: String? { presentedPrice ?? product?.displayPrice }

    /// Starts selling, once: the transaction listener, the unfinished sweep, the first read and the product.
    /// `onAccessChange` hears every change of `access` from then on. Does nothing in a build that cannot sell.
    func start(onAccessChange: @escaping @MainActor (ProAccess) -> Void) {
        guard isEnforced, !isPresented, updates == nil else { return }
        self.onAccessChange = onAccessChange
        #if APP_STORE_BUILD
        logger.notice("Selling Pro (\(StoreBuild.marker, privacy: .public))")
        #endif
        updates = Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.process(result)
            }
        }
        Task {
            for await result in Transaction.unfinished {
                await process(result)
            }
            await refresh()
            await loadProduct()
        }
    }

    /// Stops listening for transactions. For tests; the app's store lives as long as the app.
    func stop() {
        updates?.cancel()
        updates = nil
        onAccessChange = nil
    }

    /// Reads the purchases StoreKit holds for this Apple Account, together with the transactions it handed over in this
    /// launch, and applies the answer unless a newer read was applied first. StoreKit is read in a detached task, so a
    /// cancelled SwiftUI `.task` cannot cut the read short.
    func refresh() async {
        guard isEnforced, !isPresented else { return }
        let ticket = refreshOrder.begin()
        let read = await Task.detached { await ProStore.currentProTransactions() }.value
        guard refreshOrder.shouldApply(ticket) else { return }
        apply(ProEntitlement(transactions: Array(Self.merge(read, handedOver).values)))
        handedOver = Self.stillHandedOver(handedOver, after: read)
    }

    /// Loads the product, unless it is loading already. A product that loaded before stays when a later load fails.
    func loadProduct() async {
        guard isEnforced, !isPresented, productState != .loading else { return }
        productState = .loading
        do {
            let loaded = try await Product.products(for: [ProProduct.id])
            if let pro = loaded.first(where: { $0.id == ProProduct.id }) {
                product = pro
            } else {
                // Usually the product is not ready in App Store Connect, or the Paid Apps Agreement is not active.
                logger.error("The App Store did not return \(ProProduct.id, privacy: .public)")
            }
        } catch {
            logger.error("The Pro product did not load: \(error.localizedDescription, privacy: .public)")
        }
        productState = product == nil ? .failed : .loaded
    }

    /// Buys Pro. `buy` is the App Store's purchase; tests may pass their own.
    func purchase(
        using buy: @MainActor (Product) async throws -> Product.PurchaseResult = { try await $0.purchase() }
    ) async {
        guard isEnforced, !isPresented, let product, purchaseState != .purchasing else { return }
        purchaseState = .purchasing
        restoreState = .idle
        do {
            switch try await buy(product) {
            case .success(let result):
                guard case .verified = result else {
                    logger.error("A purchase came back unverified; Pro stays off")
                    purchaseState = .failed(ProCopy.unverifiedPurchase)
                    return
                }
                await process(result)
                purchaseState = .idle
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = Self.isCancellation(error) ? .idle : .failed(ProCopy.purchaseFailed(error))
        }
    }

    /// Restore Purchases: asks the App Store for this Apple Account's purchases (`sync`, which may ask the user to sign
    /// in), then reads them. A closed sign-in is not an error.
    func restore(using sync: @MainActor () async throws -> Void = { try await AppStore.sync() }) async {
        guard isEnforced, !isPresented, restoreState != .restoring else { return }
        restoreState = .restoring
        if case .failed = purchaseState { purchaseState = .idle }  // an old error should not sit under this attempt
        do {
            try await sync()
        } catch {
            restoreState = Self.isCancellation(error) ? .idle : .failed(ProCopy.restoreFailed(error))
            return
        }
        await refresh()
        restoreState = access == .pro ? .restored : .nothingFound
    }

    /// Shows a state as it is, for renders and screenshots: nothing is read or bought afterwards.
    func present(
        status: Status, displayPrice: String? = nil, productState: ProductState? = nil,
        purchaseState: PurchaseState = .idle, restoreState: RestoreState = .idle
    ) {
        isPresented = true
        self.status = status
        presentedPrice = displayPrice
        self.productState = productState ?? (displayPrice == nil ? .idle : .loaded)
        self.purchaseState = purchaseState
        self.restoreState = restoreState
    }

    /// `first` and `second` together, by transaction ID. A transaction in both is revoked when either says so: a refund is
    /// never undone, and a read that has not caught up yet must not bring a refunded purchase back.
    static func merge(
        _ first: [UInt64: ProTransaction], _ second: [UInt64: ProTransaction]
    ) -> [UInt64: ProTransaction] {
        first.merging(second) { a, b in ProTransaction(productID: a.productID, isRevoked: a.isRevoked || b.isRevoked) }
    }

    /// The handed-over transactions to keep after a read that returned `read`: a refund, and a purchase the read does not
    /// have yet.
    static func stillHandedOver(
        _ handedOver: [UInt64: ProTransaction], after read: [UInt64: ProTransaction]
    ) -> [UInt64: ProTransaction] {
        handedOver.filter { id, transaction in transaction.isRevoked || read[id] == nil }
    }

    /// Whether `error` means the user closed the App Store's sheet: not a failure.
    static func isCancellation(_ error: any Error) -> Bool {
        if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError { return true }
        return error is CancellationError
    }

    // MARK: Transactions

    /// Applies a transaction: it counts from now on (`handedOver`), and the purchases are read again. Then it is
    /// finished. An unverified one unlocks nothing and is left unfinished.
    private func process(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            logger.error("An App Store transaction could not be verified; it unlocks nothing")
            return
        }
        if transaction.productID == ProProduct.id {
            handedOver = Self.merge(handedOver, [transaction.id: ProTransaction(transaction)])
        }
        await refresh()
        await transaction.finish()
    }

    /// The newest transaction of Pro, when it verifies, by its ID; it carries a refund as its `revocationDate`. Read
    /// through `Transaction.latest(for:)`, which was up to date the moment a purchase returned and when
    /// `Transaction.updates` delivered a purchase or a refund. `Transaction.currentEntitlements` still lacked a new
    /// purchase for about 0.4 s then (StoreKit testing, 2026-10-14). Either can lag behind a purchase made elsewhere for
    /// a moment, which `handedOver` covers.
    nonisolated private static func currentProTransactions() async -> [UInt64: ProTransaction] {
        guard case .verified(let transaction)? = await Transaction.latest(for: ProProduct.id) else { return [:] }
        return [transaction.id: ProTransaction(transaction)]
    }

    private func apply(_ entitlement: ProEntitlement) {
        let before = access
        status = entitlement.access == .pro ? .pro : .free
        cache?.save(ProAccessRecord(access: entitlement.access, verifiedAt: Date()))
        if entitlement.access == .pro, purchaseState == .pending { purchaseState = .idle }
        if access != before { onAccessChange?(access) }
    }
}

extension ProTransaction {
    /// The facts of a verified StoreKit transaction.
    init(_ transaction: Transaction) {
        self.init(productID: transaction.productID, isRevoked: transaction.revocationDate != nil)
    }
}
