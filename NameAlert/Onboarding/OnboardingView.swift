import NameAlertRuntime
import SwiftUI

/// First-launch setup. Placeholder until the setup steps land; it changes nothing, so it cannot start listening.
struct OnboardingView: View {
    var body: some View {
        ContentUnavailableView("Welcome to \(AppInfo.displayName)", systemImage: "ear")
            .frame(minWidth: 600, minHeight: 460)
    }
}
