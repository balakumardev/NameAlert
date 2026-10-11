import AppKit
import NameAlertRuntime
import SwiftUI

/// The window that opens from the menu bar icon, 340 pt wide: what NameAlert is doing, the last words heard, the
/// recent mentions, and the everyday actions. It draws no background of its own: the menu bar window's material
/// shows through.
///
/// Layout: text starts 16 pt from the edges; row highlights and notes start 8 pt from them.
struct MenuBarPopover: View {
    static let width: CGFloat = 340

    @Environment(ListeningController.self) private var controller

    private let isAddingKeyword: Bool

    /// `isAddingKeyword` opens the new keyword field from the start, for renders.
    init(isAddingKeyword: Bool = false) {
        self.isAddingKeyword = isAddingKeyword
    }

    var body: some View {
        let isListening = if case .listening = controller.state { true } else { false }
        let notificationsAreOff = PopoverNotices.showsNotificationsOff(
            configuration: controller.configuration, permissions: controller.permissions)
        let hasNotices = PopoverNotices.isShown(
            state: controller.state, warnings: controller.warnings, notificationsAreOff: notificationsAreOff)
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, isListening || hasNotices ? 8 : 12)
            PopoverNotices()
            if isListening {
                LiveStrip()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            SectionDivider()
            RecentHitsList()
                .padding(8)
            SectionDivider()
            PopoverActions(isAddingKeyword: isAddingKeyword)
            SectionDivider()
            PopoverFooter()
        }
        .frame(width: Self.width)
        // A permission may have been turned on or off since the popover was last open: look again when it opens.
        .task { await controller.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await controller.refreshPermissions() }
        }
    }
}

/// A separator between the popover's sections, inset like a menu's.
private struct SectionDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 12)
    }
}
