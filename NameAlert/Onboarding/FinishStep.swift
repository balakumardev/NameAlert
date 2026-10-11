import NameAlertRuntime
import ServiceManagement
import SwiftUI

/// Step 6: where the app is now. A picture of the menu bar with the icon marked, an arrow toward it, and the choice to
/// open at login.
struct FinishStep: View {
    static var headline: String { "\(AppInfo.displayName) lives in your menu bar." }
    static let details = ["Click the ear to pause, snooze or see what it heard.", "Settings are in the same menu."]
    static let openAtLoginTitle = "Open at login"

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
            OpenAtLoginChoice()
                .padding(.top, 2)
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Open at login" on the last step: off until it is turned on, and the same login item as Settings → General's. When
/// the system wants the user to approve it, or could not change it, it says so under the checkbox.
private struct OpenAtLoginChoice: View {
    @Environment(\.loginItem) private var loginItem
    @Environment(ListeningController.self) private var controller

    @State private var status: SMAppService.Status = .notRegistered
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 6) {
            Toggle(FinishStep.openAtLoginTitle, isOn: binding)
                .toggleStyle(.checkbox)
                .accessibilityLabel(FinishStep.openAtLoginTitle)
            if LoginItemLogic.needsApproval(status) {
                VStack(spacing: 4) {
                    Text(verbatim: "Allow \(AppInfo.displayName) in System Settings → General → Login Items.")
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                        .controlSize(.small)
                        .accessibilityLabel("Open Login Items in System Settings")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { LoginItemLogic.isOn(status) },
            set: { wanted in
                let outcome = Self.turn(wanted, using: loginItem)
                status = outcome.status
                failure = outcome.failure
                remember(LoginItemLogic.isOn(outcome.status))
            })
    }

    /// Reads what the system says now (the user may have set the login item in System Settings before).
    private func refresh() {
        status = loginItem.status
        remember(LoginItemLogic.isOn(status))
    }

    /// Keeps the saved setting in step with the login item, as Settings → General does.
    private func remember(_ isOn: Bool) {
        guard controller.configuration.general.launchAtLogin != isOn else { return }
        controller.edit { $0.general.launchAtLogin = isOn }
    }

    /// Turns the login item on or off. Returns how it stands afterwards, and what to tell the user if that did not work.
    static func turn(
        _ wanted: Bool, using service: any LoginItemService
    ) -> (status: SMAppService.Status, failure: String?) {
        let failure = LoginItemLogic.change(to: wanted, using: service)
        return (service.status, failure)
    }
}

extension FinishStep {
    /// What turning "Open at login" on or off does, for the tests.
    static func openAtLogin(
        _ wanted: Bool, using service: any LoginItemService
    ) -> (status: SMAppService.Status, failure: String?) {
        OpenAtLoginChoice.turn(wanted, using: service)
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
