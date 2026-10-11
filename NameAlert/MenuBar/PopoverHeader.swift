import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// The top of the popover: a colored dot and what NameAlert is doing, the speech engine under it, and the
/// pause / play button.
struct PopoverHeader: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router

    var body: some View {
        let state = controller.state
        let engine = Self.engine(for: state, active: controller.activeEngine, configuration: controller.configuration)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    StatusDot(state: state)
                    StatusText(state: state)
                        .font(.headline)
                        .lineLimit(1)
                }
                if let engine {
                    Text(verbatim: StatusText.engineName(engine))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 16)  // under the status text, past the dot
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            toggleButton(pauses: Self.togglePauses(state))
        }
    }

    private func toggleButton(pauses: Bool) -> some View {
        let label = pauses ? "Pause listening" : "Start listening"
        return Button(action: toggle) {
            Image(systemName: pauses ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggle() {
        // Before setup is done, starting would ask for permissions out of the blue: finish setup instead.
        if !Self.togglePauses(controller.state), !controller.configuration.hasCompletedOnboarding {
            Self.openSetup(on: router)
            return
        }
        Task { await controller.toggle() }
    }

    /// Brings setup forward as it is, with what was typed in it: pressing play is not asking to start setup over (only
    /// "Run Setup Again" and a fresh launch do that).
    static func openSetup(on router: WindowRouter) {
        router.open(.onboarding, startsOver: false)
    }

    /// Whether the button pauses (listening, getting ready, waiting for a call, snoozed) rather than starts, as
    /// `ListeningController.toggle()` does.
    static func togglePauses(_ state: ListeningState) -> Bool {
        switch state {
        case .listening, .preparing, .waitingForCall, .snoozed: true
        case .off, .error: false
        }
    }

    /// The engine to name under the status: the one listening or getting ready, or the local model being
    /// downloaded.
    static func engine(for state: ListeningState, active: EngineID?, configuration: AppConfiguration) -> EngineID? {
        switch state {
        case .listening(let info):
            info.engine
        case .preparing(.downloadingModel):
            active ?? (configuration.speech.localModelSize == .light ? .whisperLight : .whisperBalanced)
        case .preparing, .waitingForCall:
            active
        case .off, .snoozed, .error:
            nil
        }
    }
}

/// Under the header: what went wrong with the button that fixes it, then the warnings, then the hint that
/// notifications are off. Nothing when all is well.
struct PopoverNotices: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let issue: ListeningIssue? = if case .error(let issue) = controller.state { issue } else { nil }
        let warnings = Self.warnings(besides: issue, in: controller.warnings)
        let notificationsAreOff = Self.showsNotificationsOff(
            configuration: controller.configuration, permissions: controller.permissions)
        if issue != nil || !warnings.isEmpty || notificationsAreOff {
            VStack(spacing: 8) {
                if let issue {
                    IssueNotice(issue: issue)
                }
                ForEach(warnings, id: \.self) { warning in
                    WarningNotice(warning: warning)
                }
                if notificationsAreOff {
                    NotificationsOffNotice()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    static let warningOrder: [RuntimeWarning] = [.screenRecordingNeedsRelaunch, .localModelFallingBehind]

    /// Whether there is anything to show: a problem, a warning, or notifications being off.
    static func isShown(state: ListeningState, warnings: Set<RuntimeWarning>, notificationsAreOff: Bool = false) -> Bool {
        if case .error = state { return true }
        return !warnings.isEmpty || notificationsAreOff
    }

    /// Whether to say that notifications are off: a rule that is on alerts with a notification, and notifications are
    /// not allowed (not yet asked for, or refused).
    static func showsNotificationsOff(configuration: AppConfiguration, permissions: PermissionsSnapshot) -> Bool {
        guard permissions.notifications != .granted else { return false }
        return configuration.rules.contains { $0.isEnabled && $0.channels.contains(.notification) }
    }

    /// The warnings to show under `issue`, in order, leaving out the one the issue's note already covers.
    static func warnings(besides issue: ListeningIssue?, in warnings: Set<RuntimeWarning>) -> [RuntimeWarning] {
        warningOrder.filter { warning in
            guard warnings.contains(warning) else { return false }
            return !(warning == .screenRecordingNeedsRelaunch && issue == .permissionDenied(.screenRecording))
        }
    }
}

/// A problem that stopped listening, with its fix.
struct IssueNotice: View {
    let issue: ListeningIssue
    /// Which permissions were asked for already; the app's own unless a test brings one.
    var asks: PermissionAsks = .shared

    @Environment(ListeningController.self) private var controller

    var body: some View {
        let fix = IssueFix(
            issue: issue, enginePreference: controller.configuration.speech.engine, warnings: controller.warnings,
            permissions: controller.permissions, hasAsked: asks.hasAsked)
        let message = fix == .relaunch ? WarningNotice.relaunchMessage : StatusText.message(for: issue)
        NoticeRow(systemImage: "exclamationmark.octagon.fill", tint: .red, message: message) {
            Button(fix.title) { perform(fix) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(fix.accessibilityLabel)
        }
    }

    private func perform(_ fix: IssueFix) {
        switch fix {
        case .allow(let permission):
            Task { await controller.ask(for: permission, asks: asks) }
        case .openSystemSettings(let permission):
            SystemSettingsLink.open(permission)
        case .relaunch:
            AppRelaunch.relaunch()
        case .useLocalModel:
            Task { await controller.update { $0.speech.engine = .localModel } }
        case .tryAgain:
            Task { await controller.start() }
        }
    }
}

/// What the button next to a problem does.
enum IssueFix: Equatable {
    /// The system has not been asked for the permission yet: ask, and it shows its own prompt.
    case allow(PermissionKind)
    /// The system will not ask again: the switch is in System Settings.
    case openSystemSettings(PermissionKind)
    /// Screen Recording is allowed, but only a new process can use it.
    case relaunch
    case useLocalModel
    case tryAgain

    /// `permissions` and `hasAsked` (which permissions were asked for already) decide between asking and System
    /// Settings; without `permissions` nothing is known, and the way out is System Settings.
    init(
        issue: ListeningIssue, enginePreference: EnginePreference, warnings: Set<RuntimeWarning> = [],
        permissions: PermissionsSnapshot? = nil, hasAsked: (PermissionKind) -> Bool = { _ in true }
    ) {
        switch issue {
        case .permissionDenied(.screenRecording) where warnings.contains(.screenRecordingNeedsRelaunch):
            self = .relaunch
        case .permissionDenied(let permission):
            guard let status = permissions?[permission] else {
                self = .openSystemSettings(permission)
                break
            }
            switch PermissionOffer(status: status, hasAsked: hasAsked(permission)) {
            case .allow: self = .allow(permission)
            case .openSystemSettings: self = .openSystemSettings(permission)
            // Allowed by now (the problem is about to clear): trying again is the one thing left to do.
            case .none: self = .tryAgain
            }
        case .engineUnavailable:
            self = enginePreference == .localModel ? .tryAgain : .useLocalModel
        case .modelMissing, .captureFailed, .engineFailed:
            self = .tryAgain
        }
    }

    var title: String {
        switch self {
        case .allow: "Allow…"
        case .openSystemSettings: "Open System Settings"
        case .relaunch: "Relaunch"
        case .useLocalModel: "Use Local Model"
        case .tryAgain: "Try Again"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .allow(let permission): "Allow \(permission.displayName)"
        case .openSystemSettings: "Open System Settings"
        case .relaunch: "Relaunch \(AppInfo.displayName)"
        case .useLocalModel: "Use the local speech model"
        case .tryAgain: "Try listening again"
        }
    }
}

/// Something to know while listening goes on.
struct WarningNotice: View {
    let warning: RuntimeWarning

    @Environment(ListeningController.self) private var controller

    static var relaunchMessage: String { "Relaunch \(AppInfo.displayName) to finish turning on system audio." }

    var body: some View {
        switch warning {
        case .localModelFallingBehind:
            NoticeRow(
                systemImage: "exclamationmark.triangle.fill", tint: .orange,
                message: Self.fallingBehindMessage(
                    usingLightModel: Self.isLight(active: controller.activeEngine, size: controller.configuration.speech.localModelSize)))
        case .screenRecordingNeedsRelaunch:
            NoticeRow(systemImage: "exclamationmark.triangle.fill", tint: .orange, message: Self.relaunchMessage) {
                Button("Relaunch") { AppRelaunch.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Relaunch \(AppInfo.displayName)")
            }
        }
    }

    /// What to say when the local model cannot keep up: switching to Light is the way out, unless Light is what is in use.
    static func fallingBehindMessage(usingLightModel: Bool) -> String {
        usingLightModel ? "Local model can't keep up." : "Local model can't keep up. Switch to Light in Settings."
    }

    /// Whether the local model in use is the Light one: the engine that is listening, else the size in the settings.
    static func isLight(active: EngineID?, size: LocalModelSize) -> Bool {
        switch active {
        case .whisperLight: true
        case .whisperBalanced: false
        default: size == .light
        }
    }
}

/// "Notifications are off", when a rule that is on alerts with a notification. The button asks for them once; after
/// that, or when they were refused, System Settings is the only place to turn them on.
struct NotificationsOffNotice: View {
    static let message = "Notifications are off."

    /// Which permissions were asked for already; the app's own unless a test brings one.
    var asks: PermissionAsks = .shared

    @Environment(ListeningController.self) private var controller

    var body: some View {
        let offer = PermissionOffer(status: controller.permissions.notifications, hasAsked: asks.hasAsked(.notifications))
        NoticeRow(systemImage: "bell.slash.fill", tint: .orange, message: Self.message) {
            Button(Self.title(for: offer)) { perform(offer) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(
                    offer == .allow ? "Turn on notifications" : "Open System Settings to turn on notifications")
        }
    }

    static func title(for offer: PermissionOffer) -> String {
        offer == .allow ? "Turn On" : "Open System Settings"
    }

    private func perform(_ offer: PermissionOffer) {
        if offer == .allow {
            Task { await controller.ask(for: .notifications, asks: asks) }
        } else {
            SystemSettingsLink.open(.notifications)
        }
    }
}
