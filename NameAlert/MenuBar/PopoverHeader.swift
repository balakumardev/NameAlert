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

/// Under the header: what went wrong with the button that fixes it, then the warnings. Nothing when all is well.
struct PopoverNotices: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        let issue: ListeningIssue? = if case .error(let issue) = controller.state { issue } else { nil }
        let warnings = Self.warnings(besides: issue, in: controller.warnings)
        if issue != nil || !warnings.isEmpty {
            VStack(spacing: 8) {
                if let issue {
                    IssueNotice(issue: issue)
                }
                ForEach(warnings, id: \.self) { warning in
                    WarningNotice(warning: warning)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    static let warningOrder: [RuntimeWarning] = [.screenRecordingNeedsRelaunch, .localModelFallingBehind]

    /// Whether there is anything to show: a problem or a warning.
    static func isShown(state: ListeningState, warnings: Set<RuntimeWarning>) -> Bool {
        if case .error = state { return true }
        return !warnings.isEmpty
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

    @Environment(ListeningController.self) private var controller

    var body: some View {
        let fix = IssueFix(issue: issue, enginePreference: controller.configuration.speech.engine, warnings: controller.warnings)
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
    case openSystemSettings(PermissionKind)
    /// Screen Recording is allowed, but only a new process can use it.
    case relaunch
    case useLocalModel
    case tryAgain

    init(issue: ListeningIssue, enginePreference: EnginePreference, warnings: Set<RuntimeWarning> = []) {
        switch issue {
        case .permissionDenied(.screenRecording) where warnings.contains(.screenRecordingNeedsRelaunch):
            self = .relaunch
        case .permissionDenied(let permission):
            self = .openSystemSettings(permission)
        case .engineUnavailable:
            self = enginePreference == .localModel ? .tryAgain : .useLocalModel
        case .modelMissing, .captureFailed, .engineFailed:
            self = .tryAgain
        }
    }

    var title: String {
        switch self {
        case .openSystemSettings: "Open Settings"
        case .relaunch: "Relaunch"
        case .useLocalModel: "Use Local Model"
        case .tryAgain: "Try Again"
        }
    }

    var accessibilityLabel: String {
        switch self {
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

    static var relaunchMessage: String { "Relaunch \(AppInfo.displayName) to finish turning on system audio." }

    var body: some View {
        switch warning {
        case .localModelFallingBehind:
            NoticeRow(
                systemImage: "exclamationmark.triangle.fill", tint: .orange,
                message: "Local model can't keep up. Switch to Light in Settings.")
        case .screenRecordingNeedsRelaunch:
            NoticeRow(systemImage: "exclamationmark.triangle.fill", tint: .orange, message: Self.relaunchMessage) {
                Button("Relaunch") { AppRelaunch.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("Relaunch \(AppInfo.displayName)")
            }
        }
    }
}
