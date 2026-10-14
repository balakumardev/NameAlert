import AppKit
import NameAlertRuntime
import SwiftUI

/// The Settings window: a sidebar of panes with the chosen one beside it.
///
/// The content is at least 760 × 540 points. The `Settings` scene turns that into the window's own minimum, and makes
/// its window fixed in size: it opens at 900 × 580, the content's 540 plus the 40 points of its compact title bar
/// (`CompactTitleBar`). The minimum only matters for a saved frame that is too small.
///
/// In the build that sells Pro (`ProStore.isEnforced`) the sidebar lists a Pro pane, and the sheet that opens where a free
/// limit is reached is shown from here (`ProUpsellAction`). `WindowRouter.openSettings(at:)` opens it on a pane.
struct SettingsView: View {
    static let minimumSize = CGSize(width: 760, height: 540)

    /// Where the pane that was open last is remembered, so Settings opens where it was left.
    static let lastSectionKey = "settings.lastSection"

    @Environment(ProStore.self) private var store: ProStore?
    @Environment(WindowRouter.self) private var router: WindowRouter?

    @State private var selection: SettingsSection
    @State private var upsell: ProUpsellReason?

    /// `section` is the pane that opens first; without it, the one that was open last time, else General.
    init(section: SettingsSection? = nil) {
        _selection = State(initialValue: section ?? Self.lastSection())
    }

    var body: some View {
        let showsPro = store?.isEnforced == true
        let shown = Self.shown(selection, showsPro: showsPro)
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding(get: { shown }, set: { if let section = $0 { selection = section } })) {
                ForEach(SettingsSection.sidebar(showsPro: showsPro)) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityLabel(section.title)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .accessibilityLabel("Settings sections")
        } detail: {
            detail(shown)
                .navigationTitle(shown.title)
        }
        .toolbar(removing: .sidebarToggle)
        .environment(\.settingsNavigation, SettingsNavigation { selection = $0 })
        .environment(\.proUpsell, ProUpsellAction { upsell = $0 })
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(CompactTitleBar())
        .onChange(of: selection) { _, section in
            UserDefaults.standard.set(section.rawValue, forKey: Self.lastSectionKey)
        }
        .onChange(of: router?.requestedSection, initial: true) {
            if let section = router?.takeRequestedSection() { selection = section }
        }
        .sheet(item: $upsell) { reason in
            if let store {
                ProUpsellSheet(reason: reason, store: store)
            }
        }
    }

    /// The pane that was open when Settings was last used.
    static func lastSection(in defaults: UserDefaults = .standard) -> SettingsSection {
        defaults.string(forKey: lastSectionKey).flatMap(SettingsSection.init(rawValue:)) ?? .general
    }

    /// The pane to show for `selection`: General in place of Pro in a build that does not sell it. (Every copy of the app
    /// shares one set of defaults, so a Debug run or a local build may find Settings left on Pro by the App Store copy.)
    static func shown(_ selection: SettingsSection, showsPro: Bool) -> SettingsSection {
        SettingsSection.sidebar(showsPro: showsPro).contains(selection) ? selection : .general
    }

    @ViewBuilder
    private func detail(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView()
        case .rules:
            RulesSettingsView()
        case .alerts:
            AlertsSettingsView()
        case .speech:
            SpeechSettingsView()
        case .history:
            HistorySettingsView()
        case .shortcuts:
            APISettingsView()
        case .pro:
            if let store {
                ProSettingsView(store: store)
            } else {
                ContentUnavailableView(ProCopy.title, systemImage: SettingsSection.pro.systemImage)
            }
        case .about:
            AboutSettingsView()
        }
    }
}

/// Gives the window the view is in the compact unified toolbar: one 40-point row with the title, the traffic lights and
/// the sidebar's toolbar. The `Settings` scene gives its window the preference style, which puts the title on a row of
/// its own above the toolbar: 88 points with the split view's toolbar. The scene ignores `windowToolbarStyle(_:)` and
/// `toolbar(.hidden, for: .windowToolbar)`, so the style is set on the window, before it is first shown.
private struct CompactTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StyleView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class StyleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.toolbarStyle = .unifiedCompact
        }
    }
}
