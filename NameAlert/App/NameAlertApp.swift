import NameAlertCore
import SwiftUI

/// Temporary skeleton while the app is rebuilt on `NameAlertKit`. Replaced when the real UI lands.
@main
struct NameAlertApp: App {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some Scene {
        MenuBarExtra("NameAlert", systemImage: "ear") {
            Text("NameAlert \(version) — rebuilding")
                // Referencing the package module here makes sure the app really links NameAlertKit.
                .accessibilityIdentifier(NameAlertCoreInfo.name)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
