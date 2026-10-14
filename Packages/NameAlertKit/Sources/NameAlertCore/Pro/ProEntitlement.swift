import Foundation

/// One verified App Store transaction, as the Pro rules see it. The app makes these from StoreKit's `Transaction`; an
/// unverified transaction never becomes one.
public struct ProTransaction: Sendable, Equatable {
    public var productID: String
    /// Refunded, or otherwise revoked by the App Store: it unlocks nothing.
    public var isRevoked: Bool

    public init(productID: String, isRevoked: Bool) {
        self.productID = productID
        self.isRevoked = isRevoked
    }
}

/// Whether the Apple Account has Pro, from the transactions StoreKit holds for it.
public struct ProEntitlement: Sendable, Equatable {
    public var access: ProAccess

    public init(access: ProAccess) {
        self.access = access
    }

    /// Pro when one of `transactions` is a purchase of `ProProduct.id` that is not revoked. Anything else, no
    /// transactions at all included, is Free.
    public init(transactions: [ProTransaction]) {
        let owned = transactions.contains { $0.productID == ProProduct.id && !$0.isRevoked }
        self.init(access: owned ? .pro : .free)
    }

    /// What the app goes by from launch until StoreKit's first answer in this launch: the last verified answer on this
    /// Mac, else Free. StoreKit answers within moments, from its own store on the Mac, offline too.
    public static func launchAccess(cached record: ProAccessRecord?) -> ProAccess {
        record?.access ?? .free
    }
}

/// Numbers the reads of the purchases, which can finish out of order, so that an older answer never replaces a newer
/// one: a slow read that started before a purchase must not turn Pro off again after it.
public struct RefreshOrder: Sendable {
    private var started: UInt64 = 0
    private var applied: UInt64 = 0

    public init() {}

    /// The number of a read that starts now.
    public mutating func begin() -> UInt64 {
        started += 1
        return started
    }

    /// Whether the read numbered `ticket` may be applied: it started after every read applied so far. If so, it counts
    /// as applied from now on.
    public mutating func shouldApply(_ ticket: UInt64) -> Bool {
        guard ticket > applied else { return false }
        applied = ticket
        return true
    }
}
