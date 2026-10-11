import AppKit
import NameAlertRuntime
import SwiftUI

/// First-time setup, one step at a time: what to listen to, the permissions, your name, the speech engine and a test.
/// It is a window of its own, 600 × 460 points and fixed in size. Setup is left by finishing it or by putting it off
/// ("Set up later" on the first step): Esc does nothing.
struct OnboardingView: View {
    static let size = CGSize(width: 600, height: 460)

    @Environment(ListeningController.self) private var controller

    /// A model to start from, for renders; the app starts from what is saved.
    var presetModel: OnboardingModel?

    var body: some View {
        OnboardingFlow(controller: controller, presetModel: presetModel)
    }
}

/// The steps, the dots and the buttons. It makes its model once, from the settings it finds when the window opens.
private struct OnboardingFlow: View {
    let controller: ListeningController

    @State private var model: OnboardingModel

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.callDetectionSupported) private var callDetectionSupported
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: ListeningController, presetModel: OnboardingModel?) {
        self.controller = controller
        _model = State(
            initialValue: presetModel
                ?? OnboardingModel(configuration: controller.configuration, step: OnboardingResume.startStep()))
    }

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .id(model.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowCentering())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.step)
        .onAppear { OnboardingResume.clear() }
        .onDisappear(perform: closed)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .source: SourceStep(model: model)
        case .permissions: PermissionsStep(model: model, continueAnyway: advance)
        case .name: NameStep(model: model, submit: { if canContinue { advance() } })
        case .engine: EngineStep(model: model)
        case .finish: FinishStep()
        }
    }

    private var canContinue: Bool {
        model.canContinue(
            permissions: controller.permissions, required: controller.requiredPermissions(),
            engineIsReady: EngineStepLogic.isReady(model.resolution, installed: controller.installedModels))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            StepDots(step: model.step)
            Spacer()
            if model.step == .welcome {
                Button("Set up later", action: putOff)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Set up later")
            } else {
                Button("Back", action: back)
                    .accessibilityLabel("Back")
            }
            if model.step == .finish {
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("Done")
            } else {
                Button("Continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canContinue)
                    .accessibilityLabel("Continue")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func advance() {
        let supportsCalls = callDetectionSupported
        Task { await model.advance(using: controller, supportsCalls: supportsCalls) }
    }

    private func back() {
        Task { await model.goBack(using: controller) }
    }

    private func finish() {
        Task {
            await model.finish(using: controller)
            dismissWindow(id: WindowID.onboarding)
        }
    }

    private func putOff() {
        Task {
            await model.putOff(using: controller)
            dismissWindow(id: WindowID.onboarding)
        }
    }

    /// The window went away. If setup was not finished, a test that turned listening on turns it off again.
    private func closed() {
        guard !model.isFinished, model.testStartedListening else { return }
        let model = model
        let controller = controller
        Task { await model.stopTest(using: controller) }
    }
}

/// The dots under the steps: one for each, the one it is at in the accent color.
struct StepDots: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { each in
                Circle()
                    .fill(each == step ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(of: step))
    }

    /// "Step 3 of 6, Permissions".
    static func description(of step: OnboardingModel.Step) -> String {
        "Step \(step.rawValue + 1) of \(OnboardingModel.Step.allCases.count), \(step.title)"
    }
}

/// The room every step but the first and the last works in: a title in the middle, a line under it, the content.
struct OnboardingStepLayout<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            content
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Puts the window in the middle of the screen when it opens. It waits a moment, so that the window has the size of
/// its content by then and the middle is the middle of that.
private struct WindowCentering: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CenteringView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class CenteringView: NSView {
        private var hasCentered = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !hasCentered, let window else { return }
            hasCentered = true
            Task { @MainActor [weak window] in
                window?.center()
            }
        }
    }
}
