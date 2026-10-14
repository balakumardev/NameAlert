import NameAlertCore
import StoreKit
import SwiftUI

/// Buy, Restore Purchases, the price from the App Store and what the purchase is, and the Terms of Use and Privacy Policy
/// links: the same on every screen that sells Pro (Settings → Pro, and the sheet where a free limit is reached).
struct ProPurchaseControls: View {
    let store: ProStore

    /// SwiftUI's purchase: it confirms the purchase in this view's window. StoreKit needs a window to anchor its sheet
    /// to, and turns a purchase down without one.
    @Environment(\.purchase) private var purchase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch store.status {
            case .notSold:
                EmptyView()
            case .checking:
                progress(ProCopy.checking)
            case .pro:
                Label(ProCopy.owned, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if store.restoreState == .restored {
                    SettingsCaption(ProCopy.restored)
                }
            case .free:
                buyRow
                purchaseNote
                SettingsCaption(ProCopy.oneTime)
                restoreRow
            }
            if store.status != .notSold {
                legalLinks
            }
        }
    }

    @ViewBuilder
    private var buyRow: some View {
        if let price = store.displayPrice {
            HStack(spacing: 8) {
                Button(ProCopy.buyTitle(price: price)) {
                    let purchase = purchase
                    Task { await store.purchase(using: { try await purchase($0) }) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.purchaseState == .purchasing || store.restoreState == .restoring)
                if store.purchaseState == .purchasing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Buying")
                }
            }
        } else if store.productState == .failed {
            VStack(alignment: .leading, spacing: 6) {
                SettingsCaption(ProCopy.priceDidNotLoad, isError: true)
                Button(ProCopy.tryAgain) {
                    Task { await store.loadProduct() }
                }
            }
        } else {
            progress(ProCopy.loadingPrice)
        }
    }

    @ViewBuilder
    private var purchaseNote: some View {
        switch store.purchaseState {
        case .pending:
            NoticeRow(systemImage: "hourglass", tint: .orange, message: ProCopy.pending)
        case .failed(let message):
            SettingsCaption(message, isError: true)
        case .idle, .purchasing:
            EmptyView()
        }
    }

    private var restoreRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(ProCopy.restoreTitle) {
                    Task { await store.restore() }
                }
                .disabled(store.restoreState == .restoring || store.purchaseState == .purchasing)
                if store.restoreState == .restoring {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Restoring")
                }
            }
            switch store.restoreState {
            case .nothingFound: SettingsCaption(ProCopy.nothingFound)
            case .failed(let message): SettingsCaption(message, isError: true)
            case .idle, .restoring, .restored: SettingsCaption(ProCopy.restoreHint)
            }
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Link(ProCopy.termsTitle, destination: AboutLinks.terms)
            Link(ProCopy.privacyTitle, destination: AboutLinks.privacy)
        }
        .font(.callout)
        .foregroundStyle(.tint)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
