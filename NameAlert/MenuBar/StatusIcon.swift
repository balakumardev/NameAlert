import AppKit
import NameAlertRuntime
import SwiftUI

/// The menu bar icon. It shows what NameAlert is doing and, because it lives as long as the app does, it is also the
/// view that opens the windows `WindowRouter` is asked for.
struct StatusIcon: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var justHeard = false

    var body: some View {
        StatusIconImage(state: controller.state, justHeard: justHeard)
            .task(id: controller.lastHitAt) { await showHit(heardAt: controller.lastHitAt) }
            .onChange(of: router.pending, initial: true) { openPendingWindow() }
    }

    /// Shows the "heard" icon until `StatusIconImage.hitHighlight` after the hit. A newer hit restarts the task.
    private func showHit(heardAt date: Date?) async {
        guard let date else { return }
        let remaining = StatusIconImage.hitHighlight - Date().timeIntervalSince(date)
        guard remaining > 0 else {
            justHeard = false
            return
        }
        justHeard = true
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        justHeard = false
    }

    private func openPendingWindow() {
        guard let destination = router.takePending() else { return }
        // A menu bar app is not in front: without this its windows open behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        if let id = destination.windowID {
            openWindow(id: id)
        } else {
            openSettings()
        }
    }
}

/// The menu bar icon's picture for a state: a template SF Symbol with a description for VoiceOver.
struct StatusIconImage: View {
    let state: ListeningState
    /// A keyword was just heard: shows `ear.badge.waveform` while listening.
    var justHeard = false

    /// How long the icon shows a hit.
    static let hitHighlight: TimeInterval = 3

    /// Every symbol the icon uses.
    static let symbolNames = ["ear", "ear.fill", "ear.badge.waveform", "moon.zzz.fill", "phone", "exclamationmark.triangle"]

    var body: some View {
        Image(systemName: Self.symbolName(for: state, justHeard: justHeard))
            .accessibilityLabel(Self.accessibilityLabel(for: state, justHeard: justHeard))
    }

    static func symbolName(for state: ListeningState, justHeard: Bool) -> String {
        switch state {
        case .off, .preparing: "ear"
        case .listening: justHeard ? "ear.badge.waveform" : "ear.fill"
        case .snoozed: "moon.zzz.fill"
        case .waitingForCall: "phone"
        case .error: "exclamationmark.triangle"
        }
    }

    static func accessibilityLabel(for state: ListeningState, justHeard: Bool) -> String {
        let status =
            switch state {
            case .off: "paused"
            case .preparing: "getting ready"
            case .listening: justHeard ? "heard a keyword" : "listening"
            case .snoozed: "snoozed"
            case .waitingForCall: "waiting for a call"
            case .error: "needs attention"
            }
        return "\(AppInfo.displayName), \(status)"
    }
}
