import NameAlertCore
import SwiftUI

/// The small "Pro" capsule beside what needs Pro, in the build that sells it. With `action`, a button that opens the Pro
/// sheet.
struct ProBadge: View {
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { capsule }
                .buttonStyle(.plain)
                .help("Part of Pro")
                .accessibilityLabel("Needs Pro. Show Pro")
        } else {
            capsule
                .accessibilityLabel("Needs Pro")
        }
    }

    private var capsule: some View {
        Text(verbatim: ProCopy.badge)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.accentColor, in: Capsule())
    }
}

/// The note at the top of the settings of an alert that needs Pro: the settings stay editable and kept; only sending
/// waits for Pro.
struct ProRequiredRow: View {
    let kind: ChannelKind
    let unlock: () -> Void

    var body: some View {
        NoticeRow(systemImage: "lock.fill", tint: .accentColor, message: ProCopy.channelSectionNote) {
            Button(ProCopy.unlockTitle, action: unlock)
                .accessibilityLabel("Unlock Pro for \(kind.displayName)")
        }
    }
}
