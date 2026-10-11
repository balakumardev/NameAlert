import SwiftUI

/// Step 6: where the app is now. A picture of the menu bar with the icon marked, and an arrow toward it.
struct FinishStep: View {
    static var headline: String { "\(AppInfo.displayName) lives in your menu bar." }
    static let details = ["Click the ear to pause, snooze or see what it heard.", "Settings are in the same menu."]

    var body: some View {
        VStack(spacing: 14) {
            MenuBarIllustration()
                .frame(height: 150)
                .accessibilityHidden(true)
            Text(verbatim: Self.headline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(Self.details, id: \.self) { line in
                    Text(verbatim: line)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The right-hand end of a menu bar with the app's ear in the accent color, and a big arrow that points up and to the
/// right at it, which is where the real one is.
struct MenuBarIllustration: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            menuBar
            Image(systemName: "arrow.up.right")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.tint)
                .offset(x: -66, y: 40)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Image(systemName: "ear.fill")
                .foregroundStyle(.white)
                .padding(5)
                .background(Color.accentColor, in: .rect(cornerRadius: 6))
            Text(verbatim: "9:41")
                .monospacedDigit()
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
