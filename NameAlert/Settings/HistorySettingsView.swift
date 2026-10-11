import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Settings → History: whether mentions are kept, the table of what was kept, and clearing it.
struct HistorySettingsView: View {
    /// How many mentions are kept.
    static let capacity = 500

    /// The height of the toggle's card with its caption, in points.
    private static let toggleHeight: CGFloat = 116

    @Environment(ListeningController.self) private var controller

    @State private var isConfirmingClear = false
    @State private var reloadToken = 0

    var body: some View {
        let isKept = controller.configuration.history.isEnabled
        HistoryLoader(reloadToken: reloadToken) { hits in
            VStack(spacing: 0) {
                Form {
                    Section {
                        Toggle("Keep a history of mentions", isOn: controller.binding(\.history.isEnabled))
                            .accessibilityLabel("Keep a history of mentions")
                    } footer: {
                        SettingsCaption(Self.explanation(isKept: isKept))
                    }
                }
                .formStyle(.grouped)
                // The height of its row and caption. (Not `fixedSize`: a form that asks for its content's height makes
                // the Settings window ask for a very tall pane, because its caption's height is measured at no width.)
                .frame(height: Self.toggleHeight)

                HistoryTable(hits: hits)
                    .padding(.horizontal, 20)

                HStack {
                    Text(verbatim: Self.count(of: hits.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { isConfirmingClear = true }
                        .disabled(hits.isEmpty)
                        .accessibilityLabel("Clear history")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved mention. It can't be undone.")
        }
    }

    private func clear() {
        Task {
            await controller.clearHistory()
            reloadToken += 1
        }
    }

    // MARK: Words

    static func explanation(isKept: Bool) -> String {
        isKept
            ? "Saved on this Mac only. The last \(capacity) mentions are kept."
            : "Nothing new is saved while this is off."
    }

    /// "No mentions", "1 mention", "5 mentions".
    static func count(of count: Int) -> String {
        switch count {
        case 0: "No mentions"
        case 1: "1 mention"
        default: "\(count) mentions"
        }
    }
}
