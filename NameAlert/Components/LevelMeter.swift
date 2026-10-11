import SwiftUI

/// Eight bars that rise and fall with the audio level (0…1), in the accent color.
struct LevelMeter: View {
    let level: Double

    /// Each bar's share of the level, so the bars make a small waveform rather than a block.
    static let profile: [Double] = [0.55, 0.85, 1.0, 0.7, 0.9, 0.6, 0.8, 0.45]
    static let barWidth: CGFloat = 3
    static let minimumHeight: CGFloat = 3
    static let maximumHeight: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.profile.indices, id: \.self) { index in
                Capsule()
                    .frame(width: Self.barWidth, height: Self.height(level: level, share: Self.profile[index]))
            }
        }
        .frame(height: Self.maximumHeight)
        .foregroundStyle(.tint)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue(StatusText.percent(level))
    }

    /// A bar's height. Speech is quiet next to full scale, so the square root lifts it: ordinary talk fills about
    /// half the meter.
    static func height(level: Double, share: Double) -> CGFloat {
        let loudness = min(max(level, 0), 1).squareRoot()
        return minimumHeight + (maximumHeight - minimumHeight) * CGFloat(min(1, loudness * share))
    }
}
