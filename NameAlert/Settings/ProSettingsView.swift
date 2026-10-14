import NameAlertCore
import SwiftUI

/// Settings → Pro, only in the build that sells it: what Pro adds, what Free keeps, and the purchase.
struct ProSettingsView: View {
    let store: ProStore

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: ProCopy.title)
                        .font(.title2.bold())
                    Text(verbatim: ProCopy.tagline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                ProAddsList()
            } header: {
                SettingsSectionTitle("What Pro adds")
            } footer: {
                SettingsCaption(ProCopy.freeKeeps)
            }

            Section {
                ProPurchaseControls(store: store)
            }
        }
        .formStyle(.grouped)
        .task {
            // A purchase screen reads the purchases again when it appears.
            await store.refresh()
            if store.product == nil { await store.loadProduct() }
        }
    }
}

/// What Pro adds, one line each, with a check mark.
struct ProAddsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ProCopy.proAdds, id: \.self) { line in
                Label {
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
