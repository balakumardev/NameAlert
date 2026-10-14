import Foundation
import NameAlertCore
import Testing

private func purchase(_ productID: String = ProProduct.id, revoked: Bool = false) -> ProTransaction {
    ProTransaction(productID: productID, isRevoked: revoked)
}

@Suite("ProEntitlement")
struct ProEntitlementTests {
    @Test func aPurchaseOfProIsPro() {
        #expect(ProEntitlement(transactions: [purchase()]) == ProEntitlement(access: .pro))
    }

    @Test func aRefundedPurchaseIsFree() {
        #expect(ProEntitlement(transactions: [purchase(revoked: true)]).access == .free)
    }

    @Test func anotherProductIsNotPro() {
        #expect(ProEntitlement(transactions: [purchase("dev.balakumar.namealert.other")]).access == .free)
    }

    @Test func noTransactionsIsFree() {
        #expect(ProEntitlement(transactions: []) == ProEntitlement(access: .free))
    }

    @Test func aPurchaseRefundedAndBoughtAgainIsPro() {
        #expect(ProEntitlement(transactions: [purchase(revoked: true), purchase()]) == ProEntitlement(access: .pro))
        #expect(ProEntitlement(transactions: [purchase(), purchase(revoked: true)]) == ProEntitlement(access: .pro))
        #expect(ProEntitlement(transactions: [purchase(revoked: true), purchase(revoked: true)]).access == .free)
    }

    @Test func aLaunchGoesByTheLastVerifiedAnswer() {
        #expect(ProEntitlement.launchAccess(cached: nil) == .free)
        #expect(ProEntitlement.launchAccess(cached: ProAccessRecord(access: .pro, verifiedAt: .distantPast)) == .pro)
        #expect(ProEntitlement.launchAccess(cached: ProAccessRecord(access: .free, verifiedAt: .now)) == .free)
    }

    @Test func anOlderReadNeverReplacesANewerOne() {
        var order = RefreshOrder()
        let older = order.begin()
        let newer = order.begin()
        let appliesNewer = order.shouldApply(newer)
        let appliesOlder = order.shouldApply(older)
        #expect(appliesNewer)
        #expect(!appliesOlder, "the read that started first came back last")
        let later = order.begin()
        let appliesLater = order.shouldApply(later)
        #expect(appliesLater)
    }

    @Test func readsThatFinishInOrderAreAllAppliedOnce() {
        var order = RefreshOrder()
        let first = order.begin()
        let second = order.begin()
        let appliesFirst = order.shouldApply(first)
        let appliesSecond = order.shouldApply(second)
        let appliesSecondAgain = order.shouldApply(second)
        #expect(appliesFirst)
        #expect(appliesSecond)
        #expect(!appliesSecondAgain)
    }
}

@Suite("ProAccessCache")
struct ProAccessCacheTests {
    /// A defaults domain of its own, removed by `finish()`.
    private struct Scratch {
        let name = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        func finish() { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    @Test func anAnswerReadsBack() {
        let scratch = Scratch()
        defer { scratch.finish() }
        let record = ProAccessRecord(access: .pro, verifiedAt: Date(timeIntervalSince1970: 1_760_000_000))
        ProAccessCache(defaults: scratch.defaults).save(record)
        #expect(ProAccessCache(defaults: scratch.defaults).load() == record)
    }

    @Test func nothingSavedIsNothing() {
        let scratch = Scratch()
        defer { scratch.finish() }
        #expect(ProAccessCache(defaults: scratch.defaults).load() == nil)
    }

    @Test func somethingUnreadableIsNothing() {
        let scratch = Scratch()
        defer { scratch.finish() }
        scratch.defaults.set(Data("not json".utf8), forKey: ProAccessCache.key)
        #expect(ProAccessCache(defaults: scratch.defaults).load() == nil)
        scratch.defaults.set("pro", forKey: ProAccessCache.key)
        #expect(ProAccessCache(defaults: scratch.defaults).load() == nil)
    }
}
