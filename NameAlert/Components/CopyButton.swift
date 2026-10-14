import AppKit
import SwiftUI

/// Puts text on the general pasteboard.
enum Pasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A small button that copies a text and says so: its icon turns into a check mark for a moment.
struct CopyButton: View {
    /// What the button puts on the pasteboard.
    let text: String
    /// What it copies, in words, for the tooltip and VoiceOver: "takeheed://start".
    let what: String

    /// How long the check mark stays.
    static let confirmationTime: Duration = .milliseconds(1500)

    @State private var isCopied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(isCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(isCopied ? "Copied" : "Copy \(what)")
        .accessibilityLabel("Copy \(what)")
        .accessibilityValue(isCopied ? "Copied" : "")
        .task(id: isCopied) {
            guard isCopied else { return }
            try? await Task.sleep(for: Self.confirmationTime)
            isCopied = false
        }
    }

    private func copy() {
        Pasteboard.copy(text)
        isCopied = true
        AccessibilityNotification.Announcement("Copied").post()
    }
}
