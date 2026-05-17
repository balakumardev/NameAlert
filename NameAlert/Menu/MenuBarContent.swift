import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var engine: ListeningEngine
    @Environment(\.openSettings) private var openSettings
    @State private var didBootstrap = false

    var body: some View {
        Group {
            statusRow
            Divider()
            Button(engine.status == .listening ? "Pause Listening" : "Start Listening") {
                Task { await engine.toggle() }
            }
            Button("Open Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit NameAlert") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await NotificationAlert.requestAuthorizationIfNeeded()
            if engine.status == .stopped {
                await engine.start()
            }
        }
    }

    private var statusRow: some View {
        switch engine.status {
        case .stopped:
            return Text("Paused")
        case .requestingPermission:
            return Text("Requesting permissions…")
        case .downloadingModel:
            return Text("Preparing model…")
        case .listening:
            return Text("Listening")
        case .error(let message):
            return Text("Error: \(message)")
        }
    }
}
