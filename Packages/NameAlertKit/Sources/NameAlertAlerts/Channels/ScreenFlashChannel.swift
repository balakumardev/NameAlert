import AppKit
import NameAlertCore

/// Flashes a border in the accent color around every screen: it fades in and out over 0.6 s, or, when Reduce Motion
/// is on, stays still for 1 s. The windows let every click through and are gone afterwards.
public struct ScreenFlashChannel: AlertChannel {
    public var kind: ChannelKind { .screenFlash }

    public init() {}

    public func deliver(_ hit: Hit, settings: ChannelSettings, secrets: any SecretStore) async throws {
        await MainActor.run { ScreenFlash.shared.flash() }
    }
}

/// What one flash does over time. (The part of the flash that needs no window.)
enum FlashPlan: Equatable {
    /// From invisible to the full border and back.
    case fade(inSeconds: Double, outSeconds: Double)
    /// The full border, not moving.
    case hold(seconds: Double)

    /// How thick the border is, in points.
    static let borderWidth: CGFloat = 8

    static func make(reduceMotion: Bool) -> FlashPlan {
        reduceMotion ? .hold(seconds: 1) : .fade(inSeconds: 0.3, outSeconds: 0.3)
    }

    var totalSeconds: Double {
        switch self {
        case .fade(let fadeIn, let fadeOut): fadeIn + fadeOut
        case .hold(let seconds): seconds
        }
    }
}

/// Puts the flash on the screens. One flash at a time: a new one takes the place of one that is still going.
@MainActor
final class ScreenFlash {
    static let shared = ScreenFlash()

    private var windows: [NSWindow] = []
    private var running: Task<Void, Never>?

    private init() {}

    func flash(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        stop()
        let plan = FlashPlan.make(reduceMotion: reduceMotion)
        let flashWindows = NSScreen.screens.map(Self.makeWindow)
        windows = flashWindows
        for window in flashWindows { window.orderFrontRegardless() }

        running = Task { [weak self] in
            switch plan {
            case .fade(let fadeIn, let fadeOut):
                await Self.fade(flashWindows, to: 1, over: fadeIn)
                guard !Task.isCancelled else { return }
                await Self.fade(flashWindows, to: 0, over: fadeOut)
            case .hold(let seconds):
                for window in flashWindows { window.alphaValue = 1 }
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Closes the windows, and ends the flash if one is still going.
    private func stop() {
        running?.cancel()
        running = nil
        for window in windows { window.close() }
        windows = []
    }

    private static func fade(_ windows: [NSWindow], to alpha: CGFloat, over seconds: Double) async {
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = seconds
            for window in windows { window.animator().alphaValue = alpha }
        }
    }

    /// A transparent window as big as the screen, with the border drawn inside its edge, that ignores the mouse.
    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setAccessibilityElement(false)

        let border = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        border.wantsLayer = true
        border.layer?.borderWidth = FlashPlan.borderWidth
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        window.contentView = border
        return window
    }
}
