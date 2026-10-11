import AppKit
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing

@testable import ScreenshotHost

@Suite("Shell renders", .serialized)
@MainActor
struct ShellRenderTests {
    @Test("Every status icon symbol exists on this system")
    func symbolsExist() {
        for name in StatusIconImage.symbolNames {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing SF Symbol \(name)")
        }
    }

    @Test("The status icon renders for every state", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func statusIcons(appearance: NSAppearance.Name) throws {
        let strip = StatusIconStrip(entries: StatusIconStrip.allStates())
        let name = appearance == .darkAqua ? "status-icons-dark" : "status-icons"
        let url = try RenderHarness.render(strip, name: name, appearance: appearance)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Each state has its own icon and description")
    func iconsDifferByState() {
        let entries = StatusIconStrip.allStates()
        let pictures = entries.map { StatusIconImage.symbolName(for: $0.state, justHeard: $0.justHeard) }
        #expect(pictures == ["ear", "ear", "ear.fill", "ear.badge.waveform", "moon.zzz.fill", "phone", "exclamationmark.triangle"])
        let labels = entries.map { StatusIconImage.accessibilityLabel(for: $0.state, justHeard: $0.justHeard) }
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { $0.hasPrefix(AppInfo.displayName) })
    }
}

/// Every state's menu bar icon side by side on a menu-bar-like strip, each named underneath.
private struct StatusIconStrip: View {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let state: ListeningState
        var justHeard = false
        /// Drawn through the real `StatusIcon` with a demo controller; `nil` draws the picture alone (a hit's
        /// highlight lives in `StatusIcon`'s own state).
        var controller: ListeningController?
    }

    let entries: [Entry]

    static func allStates() -> [Entry] {
        let states: [(String, ListeningState)] = [
            ("Off", .off),
            ("Preparing", .preparing(.starting)),
            ("Listening", .listening(DemoFixtures.listeningInfo)),
        ]
        var entries = states.map { Entry(title: $0.0, state: $0.1, controller: DemoFixtures.controller($0.1)) }
        entries.append(Entry(title: "Heard", state: .listening(DemoFixtures.listeningInfo), justHeard: true))
        let more: [(String, ListeningState)] = [
            ("Snoozed", .snoozed(until: DemoFixtures.today(10, 45))),
            ("Call", .waitingForCall),
            ("Error", .error(.permissionDenied(.screenRecording))),
        ]
        entries += more.map { Entry(title: $0.0, state: $0.1, controller: DemoFixtures.controller($0.1)) }
        return entries
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(entries) { entry in
                VStack(spacing: 8) {
                    icon(for: entry)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text(entry.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 56)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func icon(for entry: Entry) -> some View {
        if let controller = entry.controller {
            StatusIcon()
                .environment(controller)
                .environment(WindowRouter())
        } else {
            StatusIconImage(state: entry.state, justHeard: entry.justHeard)
        }
    }
}
