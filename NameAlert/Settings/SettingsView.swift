import NameAlertRuntime
import SwiftUI

/// The Settings window: a sidebar of panes with the chosen one beside it.
///
/// The content is at least 760 × 540 points. The `Settings` scene turns that into the window's own minimum, which was
/// read back from the open window: `contentMinSize` 760 × 628, the content's 540 plus 88 points of title bar and
/// toolbar. The scene makes its window fixed in size, so it opens at 900 × 628 and the minimum only matters for a
/// saved frame that is too small.
struct SettingsView: View {
    static let minimumSize = CGSize(width: 760, height: 540)

    @State private var selection: SettingsSection

    /// `section` is the pane that opens first.
    init(section: SettingsSection = .general) {
        _selection = State(initialValue: section)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: sidebarSelection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityLabel(section.title)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .accessibilityLabel("Settings sections")
        } detail: {
            detail
                .navigationTitle(selection.title)
        }
        .toolbar(removing: .sidebarToggle)
        .environment(\.settingsNavigation, SettingsNavigation { selection = $0 })
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    /// The sidebar's selection: one pane is always chosen.
    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(
            get: { selection },
            set: { if let section = $0 { selection = section } })
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .rules:
            RulesSettingsView()
        case .alerts, .speech, .history, .shortcuts, .about:
            // These panes arrive with their own tasks.
            ContentUnavailableView(selection.title, systemImage: selection.systemImage)
        }
    }
}
