import NameAlertCore
import SwiftUI

/// One permission as a card: an icon, what it is for, whether it is allowed, and the button that gets it allowed.
struct PermissionCard: View {
    let kind: PermissionKind
    let status: PermissionStatus
    /// The user was asked for it during this setup and it is still not allowed.
    var hasAsked = false
    /// Not needed to listen, only recommended.
    var isOptional = false
    /// Screen Recording is allowed, but listening may only see it once the app has opened again.
    var showsRelaunch = false
    var allow: () -> Void = {}
    var openSettings: () -> Void = {}
    var relaunch: () -> Void = {}

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let title = Self.title(for: kind)
        let pill = Self.pill(for: status, hasAsked: hasAsked)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: Self.symbol(for: kind))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                        .font(.headline)
                    PermissionPill(pill: pill)
                    if isOptional {
                        Text("Recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: Self.reason(for: kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsRelaunch {
                    Text(verbatim: Self.relaunchNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButton(title: title)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(title: String) -> some View {
        if showsRelaunch && status == .granted {
            Button("Relaunch \(AppInfo.displayName)", action: relaunch)
                .fixedSize()
                .accessibilityLabel("Relaunch \(AppInfo.displayName)")
        } else {
            switch Self.action(for: status, hasAsked: hasAsked) {
            case .allow:
                Button("Allow", action: allow)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Allow \(title)")
            case .openSettings:
                Button("Open System Settings", action: openSettings)
                    .fixedSize()
                    .accessibilityLabel("Open System Settings for \(title)")
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: Words and rules

    /// What the button does.
    enum Action: Equatable {
        /// Ask: the system shows its prompt.
        case allow
        /// The system will not ask again (or did and the answer was no): the user changes it in System Settings.
        case openSettings
        case none
    }

    static func action(for status: PermissionStatus, hasAsked: Bool) -> Action {
        switch status {
        case .granted: .none
        case .denied: .openSettings
        // macOS says nothing about a Screen Recording prompt that was answered "no": after one request, still not
        // allowed means the user has to turn it on in System Settings.
        case .notDetermined: hasAsked ? .openSettings : .allow
        }
    }

    struct Pill: Equatable {
        enum Tone: Equatable { case good, bad, neutral }
        let text: String
        let tone: Tone
    }

    static func pill(for status: PermissionStatus, hasAsked: Bool) -> Pill {
        switch status {
        case .granted: Pill(text: "Allowed", tone: .good)
        case .denied: Pill(text: "Not allowed", tone: .bad)
        case .notDetermined: hasAsked ? Pill(text: "Not allowed", tone: .bad) : Pill(text: "Not asked yet", tone: .neutral)
        }
    }

    static func title(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .speechRecognition: "Speech Recognition"
        case .notifications: "Notifications"
        }
    }

    static func reason(for kind: PermissionKind) -> String {
        let app = AppInfo.displayName
        return switch kind {
        case .microphone: "Lets \(app) hear the people around you."
        case .screenRecording: "Lets \(app) hear calls, meetings and videos on this Mac. Only the sound is used."
        case .speechRecognition: "Lets \(app) turn speech into text on this Mac."
        case .notifications: "Shows an alert when someone says your name."
        }
    }

    static func symbol(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "mic.fill"
        case .screenRecording: "display"
        case .speechRecognition: "waveform"
        case .notifications: "bell.badge.fill"
        }
    }

    /// Under the Screen Recording card once it was turned on while setup was open.
    static var relaunchNote: String {
        "Not working yet? Relaunch \(AppInfo.displayName)."
    }
}

/// The small rounded label that says whether a permission is allowed: a colored dot and the words in the text color
/// (the words stay readable on any background; the dot carries the color).
private struct PermissionPill: View {
    let pill: PermissionCard.Pill

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let color = tint
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(verbatim: pill.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: .capsule)
        .overlay {
            if contrast == .increased { Capsule().strokeBorder(color.opacity(0.7)) }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch pill.tone {
        case .good: .green
        case .bad: .red
        case .neutral: Color(nsColor: .secondaryLabelColor)
        }
    }
}
