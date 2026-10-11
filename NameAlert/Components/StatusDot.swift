import AppKit
import NameAlertRuntime
import SwiftUI

/// A small dot in the color of a listening state: green listening; orange getting ready, waiting for a call or
/// snoozed; gray off; red when something is wrong.
struct StatusDot: View {
    let state: ListeningState
    var diameter: CGFloat = 8

    var body: some View {
        let color = Self.color(for: state)
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .background {
                if case .listening = state {
                    // A soft halo, so "on" reads at a glance.
                    Circle()
                        .fill(color.opacity(0.25))
                        .frame(width: diameter * 2, height: diameter * 2)
                }
            }
            .accessibilityHidden(true)  // the status text next to it says the same
    }

    /// The color that stands for `state` everywhere in the app.
    static func color(for state: ListeningState) -> Color {
        switch state {
        case .listening: .green
        case .preparing, .waitingForCall, .snoozed: .orange
        case .off: Color(nsColor: .systemGray)
        case .error: .red
        }
    }
}
