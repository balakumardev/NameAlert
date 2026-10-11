import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// The last five mentions, newest first; each opens History. "No mentions yet" until there is one.
struct RecentHitsList: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    static let limit = 5

    var body: some View {
        let hits = Array(controller.recentHits.prefix(Self.limit))
        if hits.isEmpty {
            Text("No mentions yet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            let now = Date()
            VStack(spacing: 0) {
                ForEach(hits) { hit in
                    Button {
                        router.open(.history)
                        dismiss()
                    } label: {
                        HitRow(hit: hit, now: now)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel(HitRow.accessibilityLabel(for: hit))
                    .accessibilityHint("Opens History")
                }
            }
        }
    }
}
