import AppKit
import NameAlertCore
import SwiftUI

/// The floating alarm: one panel, one looping sound, one auto-stop timer, whatever the number of hits.
///
/// It is a non-activating panel, so it never takes the keyboard from the app the user is working in, and it floats
/// above other windows on every Space and above full-screen apps, at the top right of the screen the mouse is on. It
/// stays until the user presses **Dismiss** or **Snooze 15 min**, or the auto-stop time is over. It does not block the
/// main thread: nothing here is modal.
///
/// What happens when is decided by `AlarmState`; this class carries it out.
@MainActor
final class AlarmPanel {
    static let shared = AlarmPanel()

    static let width: CGFloat = 340
    static let snoozeMinutes = 15

    private var state = AlarmState()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AlarmView>?
    private var sound: NSSound?
    private var timer: Task<Void, Never>?
    private var onSnooze: (@Sendable (Int) async -> Void)?
    private let logger = Log.logger("alarm")

    private init() {}

    /// Shows the alarm for `hit`, or, if it is showing, changes its words and starts the auto-stop time over.
    func present(_ hit: Hit, settings: PersistentAlarmSettings, onSnooze: @escaping @Sendable (Int) async -> Void) {
        self.onSnooze = onSnooze
        perform(
            state.present(
                AlarmContent(hit: hit), soundName: settings.soundName, autoStopSeconds: settings.autoStopSeconds))
    }

    func dismiss() {
        perform(state.dismiss())
    }

    func snooze() {
        perform(state.snooze(minutes: Self.snoozeMinutes))
    }

    private func timerFired(_ generation: Int) {
        perform(state.timerFired(generation: generation))
    }

    // MARK: Effects

    private func perform(_ effects: [AlarmState.Effect]) {
        for effect in effects {
            switch effect {
            case .open(let content): open(content)
            case .update(let content): update(content)
            case .startSound(let name): startSound(named: name)
            case .armTimer(let generation, let seconds): armTimer(generation: generation, seconds: seconds)
            case .stopSound: stopSound()
            case .snooze(let minutes): requestSnooze(minutes: minutes)
            case .close: close()
            }
        }
    }

    private func open(_ content: AlarmContent) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        setContent(content, in: panel)
        let screens = NSScreen.screens
        let index = AlarmPlacement.screenIndex(containing: NSEvent.mouseLocation, in: screens.map(\.frame))
        if let screen = index.map({ screens[$0] }) ?? NSScreen.main ?? screens.first {
            panel.setFrameOrigin(AlarmPlacement.origin(for: panel.frame.size, in: screen.visibleFrame))
        }
        panel.orderFrontRegardless()
    }

    private func update(_ content: AlarmContent) {
        guard let panel else { return }
        setContent(content, in: panel)
    }

    /// Puts `content` in the panel and makes the panel as high as it needs to be, keeping its top edge in place
    /// (and with it the place the user may have dragged it to).
    private func setContent(_ content: AlarmContent, in panel: NSPanel) {
        let view = AlarmView(
            content: content,
            onDismiss: { [weak self] in self?.dismiss() },
            onSnooze: { [weak self] in self?.snooze() })
        let hostingView: NSHostingView<AlarmView>
        if let existing = self.hostingView {
            existing.rootView = view
            hostingView = existing
        } else {
            hostingView = NSHostingView(rootView: view)
            self.hostingView = hostingView
            panel.contentView = hostingView
        }

        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    private func close() {
        timer?.cancel()
        timer = nil
        panel?.orderOut(nil)
    }

    private func startSound(named name: String) {
        // A copy, so that the looping alarm and the one-time sound channel never share a sound object (the system
        // hands out one for each name), whichever names the user picked.
        guard let named = NSSound(named: NSSound.Name(name)), let copy = named.copy() as? NSSound else {
            logger.error("The alarm sound could not be loaded")
            return
        }
        copy.loops = true
        if !copy.play() { logger.error("The alarm sound could not be played") }
        sound = copy
    }

    private func stopSound() {
        sound?.stop()
        sound = nil
    }

    private func armTimer(generation: Int, seconds: Int) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.timerFired(generation)
        }
    }

    private func requestSnooze(minutes: Int) {
        guard let onSnooze else { return }
        Task { await onSnooze(minutes) }
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "NameAlert"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false  // the app is never the active one; the default would hide the panel at once
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("NameAlert alarm")
        return panel
    }
}

/// What the alarm panel shows: the title, the rule, the words around the term, what was said just before them (when
/// the hit has it), and the two buttons.
struct AlarmView: View {
    /// How many lines of the excerpt show before it needs scrolling.
    static let excerptLines = 5

    let content: AlarmContent
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(content.ruleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !content.context.isEmpty {
                Text(content.context)
                    .font(.body)
            }
            if let excerpt = content.excerpt {
                AlarmExcerptView(text: excerpt)
            }
            HStack {
                Spacer()
                Button("Snooze 15 min", action: onSnooze)
                    .accessibilityLabel("Snooze for 15 minutes")
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Dismiss the alarm")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)  // the title bar above already gives the top its room
        .frame(width: AlarmPanel.width, alignment: .leading)
    }
}

/// What was said just before the term, in a box that holds `AlarmView.excerptLines` lines at most: secondary-colored
/// text that can be selected, and scrolls when it is longer. The excerpt ends with the term, so a long one starts out
/// scrolled to its end, where the words that matter most are.
struct AlarmExcerptView: View {
    let text: String

    var body: some View {
        // The invisible copy, limited to the lines allowed, sets the size of the box: as high as the text is, but
        // never higher than that many lines. The scrolling copy lies over it. That way nothing has to be measured,
        // and the size is right the first time the panel lays itself out, which is when its window gets its height.
        Text(text)
            .font(.callout)
            .lineLimit(AlarmView.excerptLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .top) {
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Recent transcript: \(text)")
                }
                .defaultScrollAnchor(.bottom)
                .id(text)  // a new hit's words start at the end again, wherever the last ones were scrolled to
            }
    }
}
