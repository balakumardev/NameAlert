import AppKit
import NameAlertRuntime
import SwiftUI

/// The window that opens from the menu bar icon. Placeholder until the popover lands (Task 6.2).
struct MenuBarPopover: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppInfo.displayName)
                .font(.headline)
            HStack {
                Button("Settings…") { router.open(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityLabel("Open Settings")
                Spacer()
                Button("Quit \(AppInfo.displayName)") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .accessibilityLabel("Quit \(AppInfo.displayName)")
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
