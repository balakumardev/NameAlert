import SwiftUI

@main
struct NameAlertApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var engine: ListeningEngine

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _engine = StateObject(wrappedValue: ListeningEngine(settings: s))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(engine)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(engine)
                .task { await bootstrap() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) { EmptyView() }
        }
    }

    private var menuBarIcon: String {
        switch engine.status {
        case .listening: return "ear.fill"
        case .error: return "ear.trianglebadge.exclamationmark"
        default: return "ear"
        }
    }

    /// Runs once when the Settings scene first attaches. Because `MenuBarExtra` is
    /// the actual app entry, the menu's own `MenuBarContent.task` (see file) is
    /// what fires on cold launch even before Settings is opened.
    private func bootstrap() async {
        await NotificationAlert.requestAuthorizationIfNeeded()
        if settings.listenAtLaunch, engine.status == .stopped {
            await engine.start()
        }
    }
}
