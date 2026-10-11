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

    /// Where the pane that was open last is remembered, so Settings opens where it was left.
    static let lastSectionKey = "settings.lastSection"

    @State private var selection: SettingsSection

    /// `section` is the pane that opens first; without it, the one that was open last time, else General.
    init(section: SettingsSection? = nil) {
        _selection = State(initialValue: section ?? Self.lastSection())
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
        .onChange(of: selection) { _, section in
            UserDefaults.standard.set(section.rawValue, forKey: Self.lastSectionKey)
        }
    }

    /// The pane that was open when Settings was last used.
    static func lastSection(in defaults: UserDefaults = .standard) -> SettingsSection {
        defaults.string(forKey: lastSectionKey).flatMap(SettingsSection.init(rawValue:)) ?? .general
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
        case .alerts:
            AlertsSettingsView()
        case .speech:
            SpeechSettingsView()
        case .history, .shortcuts, .about:
            // These panes arrive with their own tasks.
            ContentUnavailableView(selection.title, systemImage: selection.systemImage)
        }
    }
}
