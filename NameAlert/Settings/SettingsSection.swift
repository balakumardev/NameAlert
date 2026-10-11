import SwiftUI

/// The panes of the Settings window, in the order of its sidebar.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, rules, alerts, speech, history, shortcuts, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .rules: "Rules"
        case .alerts: "Alerts"
        case .speech: "Speech"
        case .history: "History"
        case .shortcuts: "Shortcuts & API"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .rules: "text.badge.checkmark"
        case .alerts: "bell"
        case .speech: "waveform"
        case .history: "clock"
        case .shortcuts: "curlybraces"
        case .about: "info.circle"
        }
    }
}

/// Sends the user to another pane from inside one ("Set up in Alerts"). Settings provides the real one.
struct SettingsNavigation {
    let show: @MainActor (SettingsSection) -> Void

    init(show: @escaping @MainActor (SettingsSection) -> Void = { _ in }) {
        self.show = show
    }
}

private struct SettingsNavigationKey: EnvironmentKey {
    static var defaultValue: SettingsNavigation { SettingsNavigation() }
}

extension EnvironmentValues {
    var settingsNavigation: SettingsNavigation {
        get { self[SettingsNavigationKey.self] }
        set { self[SettingsNavigationKey.self] = newValue }
    }
}

/// The title of a settings section: `.headline`, like the status line in the popover.
struct SettingsSectionTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(verbatim: title)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A line of explanation under a control: small and in the secondary color. It wraps rather than truncates.
struct SettingsCaption: View {
    private let text: Text
    private let isError: Bool

    /// Plain text, shown as it is.
    init(_ text: String, isError: Bool = false) {
        self.text = Text(verbatim: text)
        self.isError = isError
    }

    var body: some View {
        text
            .font(.callout)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
