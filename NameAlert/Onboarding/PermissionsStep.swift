import AppKit
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Step 3: the permissions listening needs, a card each, and notifications as a recommended extra. The cards read the
/// permissions again whenever the app comes forward (after the user turned one on in System Settings).
struct PermissionsStep: View {
    @Bindable var model: OnboardingModel
    /// Goes on although something that is needed is not allowed yet.
    var continueAnyway: () -> Void

    /// Which permissions were asked for, in this setup or an earlier run; the app's own unless a test brings one.
    var asks: PermissionAsks = .shared
    /// The other copies of the app LaunchServices knows about; the app's own unless a test brings some.
    var otherCopies: OtherCopies = .shared

    @Environment(ListeningController.self) private var controller

    /// The most height the cards take before they scroll: what the step has left under its title.
    static let cardsHeight: CGFloat = 252

    var body: some View {
        let required = controller.requiredPermissions()
        let permissions = controller.permissions
        OnboardingStepLayout(
            title: "Turn on what \(AppInfo.displayName) needs",
            subtitle: "macOS asks you first. You can change any of these later in System Settings."
        ) {
            VStack(spacing: 8) {
                // Three or four cards (both sources, with Speech Recognition) are taller than the step: they scroll.
                CappedScrollView(maxHeight: Self.cardsHeight, startsAtEnd: false) {
                    VStack(spacing: 8) {
                        ForEach(required, id: \.self) { kind in
                            card(kind, isOptional: false, permissions: permissions)
                        }
                        card(.notifications, isOptional: true, permissions: permissions)
                    }
                    .padding(.vertical, 1)  // the cards' borders are not cut off at the edge
                }
                if !Self.allAllowed(required, in: permissions) {
                    Button("Continue anyway", action: continueAnyway)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.top, 4)
                        .accessibilityLabel("Continue anyway, without allowing everything")
                }
            }
        }
        .task {
            await controller.refreshPermissions()
            _ = await controller.resolvedEngine()  // the engine decides whether Speech Recognition is needed too
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.refreshPermissions() }
        }
        .onChange(of: permissions.screenRecording, initial: true) { _, status in
            if status != .granted { model.screenRecordingWasOff = true }
        }
    }

    private func card(_ kind: PermissionKind, isOptional: Bool, permissions: PermissionsSnapshot) -> some View {
        let status = permissions[kind]
        return PermissionCard(
            kind: kind, status: status, hasAsked: asks.hasAsked(kind), isOptional: isOptional,
            showsRelaunch: Self.showsRelaunch(
                kind, status: status, wasOff: model.screenRecordingWasOff,
                needsRelaunch: controller.warnings.contains(.screenRecordingNeedsRelaunch)),
            otherCopyNote: Self.otherCopyNote(kind, status: status, copies: otherCopies.urls),
            allow: { allow(kind) },
            openSettings: { openSettings(kind) },
            relaunch: relaunch)
    }

    // MARK: Actions

    private func allow(_ kind: PermissionKind) {
        // Allowing Screen Recording usually ends with the app being asked to quit and open again.
        if kind == .screenRecording { OnboardingResume.mark() }
        Task { await controller.ask(for: kind, asks: asks) }
    }

    private func openSettings(_ kind: PermissionKind) {
        if kind == .screenRecording { OnboardingResume.mark() }
        SystemSettingsLink.open(kind)
    }

    private func relaunch() {
        OnboardingResume.mark()
        AppRelaunch.relaunch()
    }

    // MARK: Rules

    /// Whether every permission in `required` is allowed.
    static func allAllowed(_ required: [PermissionKind], in permissions: PermissionsSnapshot) -> Bool {
        required.allSatisfy { permissions[$0] == .granted }
    }

    /// Whether the Screen Recording card offers a relaunch: it is allowed now, and either it was not when setup opened
    /// (macOS usually wants the app opened again for it to see the change) or capture was refused although it is.
    static func showsRelaunch(_ kind: PermissionKind, status: PermissionStatus, wasOff: Bool, needsRelaunch: Bool) -> Bool {
        kind == .screenRecording && status == .granted && (wasOff || needsRelaunch)
    }

    /// The note about another copy of the app, on the Screen Recording card until it is allowed: allowing it is when
    /// macOS asks to quit and reopen the app, and may open the other copy.
    static func otherCopyNote(_ kind: PermissionKind, status: PermissionStatus, copies: [URL]) -> String? {
        kind == .screenRecording && status != .granted ? OtherCopies.note(for: copies) : nil
    }
}
