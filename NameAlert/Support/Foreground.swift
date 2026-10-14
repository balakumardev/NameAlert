import AppKit
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Brings the app, and one of its windows, in front of the app the user is in.
///
/// A menu bar app does not come forward by itself: after a system permission prompt was answered, after a switch was
/// turned on in System Settings, or when macOS opened it again, setup stayed behind the app in front. Since macOS 14
/// activating is a request the system may turn down, so the window is also put in front of the other apps' windows.
@MainActor
enum Foreground {
    /// Activates the app and puts `window` in front. Not in tests and renders, which must not take the screen.
    static func bring(_ window: NSWindow) {
        guard AppEnvironment.isLive else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Whether asking for `kind` waits for the user's answer, so that the window that asked comes forward after it.
    /// Screen Recording's request returns at once: the answer is given in System Settings, where setup sees it change.
    nonisolated static func raisesAfterAsking(for kind: PermissionKind) -> Bool {
        kind != .screenRecording
    }

    /// Whether a permission in `required` was turned on between the readings `before` and `after`.
    nonisolated static func becameAllowed(
        _ required: [PermissionKind], before: PermissionsSnapshot, after: PermissionsSnapshot
    ) -> Bool {
        required.contains { before[$0] != .granted && after[$0] == .granted }
    }
}

/// A weak hold on the window a view is in. `WindowReader` fills it.
@MainActor
final class WindowHandle {
    weak var window: NSWindow?
}

/// Puts the window the view is in into `handle`, and calls `opened` with it once: a moment after the view is first in a
/// window, so that the window has the size of its content by then.
struct WindowReader: NSViewRepresentable {
    var handle: WindowHandle?
    var opened: (@MainActor (NSWindow) -> Void)?

    func makeNSView(context: Context) -> NSView {
        ReaderView(handle: handle, opened: opened)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        private let handle: WindowHandle?
        private let opened: (@MainActor (NSWindow) -> Void)?
        private var hasOpened = false

        init(handle: WindowHandle?, opened: (@MainActor (NSWindow) -> Void)?) {
            self.handle = handle
            self.opened = opened
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle?.window = window
            guard !hasOpened, let window, opened != nil else { return }
            hasOpened = true
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.opened?(window)
            }
        }
    }
}
