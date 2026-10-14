import NameAlertCore
import SwiftUI

/// Why the Pro sheet opened: a free limit was reached.
enum ProUpsellReason: Hashable, Identifiable {
    /// A new rule, with Free's most rules there already.
    case ruleLimit
    /// An alert that leaves the Mac was chosen.
    case channel(ChannelKind)

    var id: Self { self }

    var title: String {
        switch self {
        case .ruleLimit: ProCopy.ruleLimitTitle
        case .channel(let kind): ProCopy.channelTitle(kind)
        }
    }

    var message: String {
        switch self {
        case .ruleLimit: ProCopy.ruleLimitMessage
        case .channel: ProCopy.channelMessage
        }
    }
}

/// Opens the Pro sheet. Settings provides the real one; elsewhere it does nothing.
struct ProUpsellAction {
    let show: @MainActor (ProUpsellReason) -> Void

    init(show: @escaping @MainActor (ProUpsellReason) -> Void = { _ in }) {
        self.show = show
    }
}

private struct ProUpsellKey: EnvironmentKey {
    static var defaultValue: ProUpsellAction { ProUpsellAction() }
}

extension EnvironmentValues {
    var proUpsell: ProUpsellAction {
        get { self[ProUpsellKey.self] }
        set { self[ProUpsellKey.self] = newValue }
    }
}

/// The sheet that opens where a free limit is reached: what was asked for, what Pro adds, and the purchase. It closes by
/// itself once Pro is on.
struct ProUpsellSheet: View {
    static let width: CGFloat = 440

    let reason: ProUpsellReason
    let store: ProStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: reason.title)
                .font(.title2.bold())
            Text(verbatim: reason.message)
                .fixedSize(horizontal: false, vertical: true)
            ProAddsList()
            Divider()
            ProPurchaseControls(store: store)
            HStack {
                Spacer()
                Button(ProCopy.notNow) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: Self.width)
        .task {
            await store.refresh()
            if store.product == nil { await store.loadProduct() }
        }
        .onChange(of: store.access) { _, access in
            if access == .pro { dismiss() }
        }
    }
}
