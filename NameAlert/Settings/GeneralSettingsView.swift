import AppKit
import NameAlertAudio
import NameAlertCore
import NameAlertRuntime
import ServiceManagement
import SwiftUI

/// Settings → General: what to listen to and when, and starting with the Mac.
struct GeneralSettingsView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(\.loginItem) private var loginItem
    @Environment(\.callDetectionSupported) private var callDetectionSupported

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginFailure: String?

    /// `loginFailure` is the note under "Open at login" from the start, for renders.
    init(loginFailure: String? = nil) {
        _loginFailure = State(initialValue: loginFailure)
    }

    var body: some View {
        let listening = controller.configuration.listening
        Form {
            Section {
                Picker("Listen to", selection: controller.binding(\.listening.source)) {
                    ForEach(AudioSourceKind.allCases, id: \.self) { source in
                        Text(verbatim: Self.title(for: source)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Listen to")
            } header: {
                SettingsSectionTitle("Listen to")
            } footer: {
                SettingsCaption(Self.explanation(for: listening.source))
            }

            Section {
                Picker("When", selection: controller.binding(\.listening.mode)) {
                    ForEach(ListeningMode.allCases, id: \.self) { mode in
                        Text(verbatim: Self.title(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!callDetectionSupported)
                .accessibilityLabel("When to listen")
            } header: {
                SettingsSectionTitle("When")
            } footer: {
                SettingsCaption(Self.explanation(for: listening.mode, callDetectionSupported: callDetectionSupported))
            }

            Section {
                Toggle(
                    "Start listening when \(AppInfo.displayName) opens",
                    isOn: controller.binding(\.listening.startOnLaunch)
                )
                .accessibilityLabel("Start listening when \(AppInfo.displayName) opens")

                Toggle("Open at login", isOn: loginBinding)
                    .accessibilityLabel("Open at login")
            } header: {
                SettingsSectionTitle("Startup")
            } footer: {
                loginNotes
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLogin)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLogin()
        }
    }

    // MARK: Open at login

    /// What goes under the login toggle: the approval it may be waiting for, and why turning it on or off failed.
    @ViewBuilder
    private var loginNotes: some View {
        let needsApproval = LoginItemLogic.needsApproval(loginStatus)
        if needsApproval || loginFailure != nil {
            VStack(alignment: .leading, spacing: 8) {
                if needsApproval {
                    SettingsCaption("Allow \(AppInfo.displayName) in System Settings → General → Login Items.")
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                        .controlSize(.small)
                        .accessibilityLabel("Open Login Items in System Settings")
                }
                if let loginFailure {
                    SettingsCaption(loginFailure, isError: true)
                }
            }
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { LoginItemLogic.isOn(loginStatus) },
            set: { wanted in
                loginFailure = LoginItemLogic.change(to: wanted, using: loginItem)
                refreshLogin()
            })
    }

    /// Shows what the system says, and keeps the saved setting in step with it: the user can change the login item in
    /// System Settings without us.
    private func refreshLogin() {
        loginStatus = loginItem.status
        let isOn = LoginItemLogic.isOn(loginStatus)
        if controller.configuration.general.launchAtLogin != isOn {
            controller.edit { $0.general.launchAtLogin = isOn }
        }
    }

    // MARK: Words

    static func title(for source: AudioSourceKind) -> String {
        switch source {
        case .systemAudio: "System audio"
        case .microphone: "Microphone"
        case .both: "Both"
        }
    }

    static func explanation(for source: AudioSourceKind) -> String {
        switch source {
        case .systemAudio: "Calls, meetings and videos playing on this Mac."
        case .microphone: "People talking near you."
        case .both: "This Mac, and people talking near you."
        }
    }

    static func title(for mode: ListeningMode) -> String {
        switch mode {
        case .always: "Always"
        case .duringCalls: "Only during calls"
        }
    }

    static func explanation(for mode: ListeningMode, callDetectionSupported: Bool) -> String {
        guard callDetectionSupported else { return "Needs macOS 14.2 or later" }
        return switch mode {
        case .always: "Listens the whole time \(AppInfo.displayName) is on."
        case .duringCalls: "Listens only while another app is using your microphone, like in a call."
        }
    }
}

// MARK: - Open at login

/// The login item, as the settings use it. `SMAppService.mainApp` is the real one; renders and tests use their own.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

extension SMAppService: LoginItemService {
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// What the login toggle shows and says, apart from the toggle itself.
enum LoginItemLogic {
    /// On when the app opens at login, or will once the user allows it in System Settings.
    static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    static func needsApproval(_ status: SMAppService.Status) -> Bool {
        status == .requiresApproval
    }

    /// Turns the login item on or off. Returns what to tell the user when that did not work, else `nil`.
    static func change(to enabled: Bool, using service: any LoginItemService) -> String? {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return nil
        } catch {
            return "Couldn't turn \(enabled ? "on" : "off") Open at login: \(error.localizedDescription)"
        }
    }
}

private struct LoginItemKey: EnvironmentKey {
    static var defaultValue: any LoginItemService { SMAppService.mainApp }
}

private struct CallDetectionSupportedKey: EnvironmentKey {
    static var defaultValue: Bool { CallDetector.isSupported }
}

extension EnvironmentValues {
    /// The login item that "Open at login" changes.
    var loginItem: any LoginItemService {
        get { self[LoginItemKey.self] }
        set { self[LoginItemKey.self] = newValue }
    }

    /// Whether this Mac can tell when a call is going on ("Only during calls").
    var callDetectionSupported: Bool {
        get { self[CallDetectionSupportedKey.self] }
        set { self[CallDetectionSupportedKey.self] = newValue }
    }
}
