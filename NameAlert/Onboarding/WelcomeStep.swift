import AppKit
import SwiftUI

/// Step 1: what the app does, in three short points.
struct WelcomeStep: View {
    static let headline = "Hear your name, even when you're not listening."

    /// The three points: a symbol and the words.
    static let points: [(symbol: String, text: String)] = [
        ("speaker.wave.2", "Works with calls, videos and the room around you"),
        ("laptopcomputer", "Runs entirely on this Mac"),
        ("bell", "You choose how to be alerted"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text(verbatim: Self.headline)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.points, id: \.text) { point in
                    HStack(spacing: 12) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(verbatim: point.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
