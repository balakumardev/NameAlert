import AppKit
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import SwiftUI

/// Step 5: which speech engine will listen (and the small download it may need), then a test: listening starts, and
/// when the name is heard, a green message says so.
struct EngineStep: View {
    @Bindable var model: OnboardingModel

    @Environment(ListeningController.self) private var controller
    @State private var actions = ModelActions()

    var body: some View {
        let resolution = model.resolution
        let isReady = EngineStepLogic.isReady(resolution, installed: controller.installedModels)
        OnboardingStepLayout(title: "Make sure it can hear you") {
            VStack(alignment: .leading, spacing: 14) {
                engineCard(resolution)
                testPanel(isReady: isReady)
            }
        }
        .task(id: controller.configuration.speech) {
            model.resolution = await controller.resolvedEngine()
        }
        .task(id: isReady) {
            await startTest(ifReady: isReady)
        }
        .onChange(of: controller.lastHitAt) {
            model.noteHits(controller.recentHits, ruleID: Self.ruleID(in: controller.configuration))
        }
        .onChange(of: model.heard) { _, heard in
            guard let heard else { return }
            AccessibilityNotification.Announcement(EngineStepLogic.successMessage(heard: heard)).post()
        }
    }

    // MARK: The engine

    private func engineCard(_ resolution: EngineResolution?) -> some View {
        let summary = EngineStepLogic.summary(for: resolution)
        let local = EngineStepLogic.model(for: resolution)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(summary.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: 36, height: 36)
                    .background(
                        summary.isProblem ? AnyShapeStyle(.red.opacity(0.14)) : AnyShapeStyle(.tint.opacity(0.14)),
                        in: .rect(cornerRadius: 8)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: summary.name)
                        .font(.headline)
                    Text(verbatim: summary.reason)
                        .font(.callout)
                        .foregroundStyle(summary.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing(for: resolution, localModel: local, isProblem: summary.isProblem)
            }
            if let local, let message = actions.messages[local] {
                SettingsCaption(message, isError: true)
            }
            if local != nil {
                sizeChoice
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }

    /// What sits at the end of the engine card: ready, the download, how far it is, or the way out of a dead end.
    @ViewBuilder
    private func trailing(for resolution: EngineResolution?, localModel local: WhisperModel?, isProblem: Bool) -> some View {
        if isProblem {
            Button("Use Local Model") {
                Task { await controller.update { $0.speech.engine = .localModel } }
            }
            .fixedSize()
            .accessibilityLabel("Use the local speech model")
        } else if let local {
            let progress = controller.modelDownloads[local] ?? controller.modelDownloads[.vad]
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                        .accessibilityLabel("Downloading the speech model")
                        .accessibilityValue(StatusText.percent(progress))
                    Text(verbatim: StatusText.percent(progress))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                    Button("Cancel") { actions.cancel(local, using: controller) }
                        .accessibilityLabel("Cancel the download")
                }
            } else if EngineStepLogic.isReady(resolution, installed: controller.installedModels) {
                ReadyLabel()
            } else {
                Button("Download · \(ModelRow.size(of: local))") { actions.download(local, using: controller) }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .accessibilityLabel("Download the speech model, \(ModelRow.size(of: local))")
            }
        } else if resolution != nil {
            ReadyLabel()
        }
    }

    /// Light or Balanced, for the local model.
    private var sizeChoice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Model size", selection: controller.binding(\.speech.localModelSize)) {
                ForEach(LocalModelSize.allCases, id: \.self) { size in
                    Text(verbatim: "\(SpeechSettingsView.title(for: size)) · \(Self.downloadSize(of: size, resolution: model.resolution))")
                        .tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Model size")
            SettingsCaption("Balanced hears more accurately. Light is easier on memory and battery.")
        }
    }

    /// "32 MB": the download of the model of `size` for the language that was picked.
    static func downloadSize(of size: LocalModelSize, resolution: EngineResolution?) -> String {
        let locale: String
        if case .engine(_, let identifier) = resolution { locale = identifier } else { locale = "en-US" }
        return ModelRow.size(of: ModelCatalog.model(size: size, localeIdentifier: locale))
    }

    // MARK: The test

    private func testPanel(isReady: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Test it")
                .font(.headline)
            if !isReady {
                Text(verbatim: EngineStepLogic.waitingForEngine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                EngineTest(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Starts listening for the test, once an engine is ready. If listening is on already, the test just uses it.
    private func startTest(ifReady isReady: Bool) async {
        guard isReady, model.testStartedAt == nil else { return }
        model.testStartedAt = Date()
        switch controller.state {
        case .off, .error, .snoozed: model.testStartedListening = true
        case .preparing, .listening, .waitingForCall: break
        }
        await controller.start()
    }

    /// The rule the test listens for.
    static func ruleID(in configuration: AppConfiguration) -> UUID? {
        configuration.rules.first { $0.name == OnboardingModel.ruleName }?.id
    }
}

/// A green check and "Ready".
private struct ReadyLabel: View {
    var body: some View {
        Label {
            Text("Ready")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// While the test runs: what listening is doing, the level and the last words, and the message when the name is heard.
private struct EngineTest: View {
    @Bindable var model: OnboardingModel

    @Environment(ListeningController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.state {
            case .listening:
                TestStrip()
            case .preparing(let stage):
                HStack(spacing: 8) {
                    StatusDot(state: controller.state)
                    Text(verbatim: StatusText.title(for: stage))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .error(let issue):
                IssueNotice(issue: issue)
            case .waitingForCall:
                NoticeRow(systemImage: "phone", tint: .orange, message: EngineStepLogic.waitingForCall)
            case .off, .snoozed:
                Text(verbatim: StatusText.title(for: .preparing(.starting)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let heard = model.heard {
                HeardBanner(heard: heard)
            } else if case .listening = controller.state {
                Text(verbatim: EngineStepLogic.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The level meter and the last words heard, in a box.
private struct TestStrip: View {
    @Environment(ListeningController.self) private var controller

    /// About how many of the last characters to show.
    static let snippetLength = 70

    var body: some View {
        HStack(spacing: 10) {
            StripLevel()
            let snippet = LiveStrip.snippet(of: controller.liveTranscript, length: Self.snippetLength)
            if snippet.isEmpty {
                Text("Listening…")
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "“\(snippet)”")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// The level meter, reading the level itself: it changes up to 15 times a second and only this view follows it.
private struct StripLevel: View {
    @Environment(ListeningController.self) private var controller

    var body: some View {
        LevelMeter(level: controller.level)
    }
}

/// "Got it — heard “Bala”", big and green.
private struct HeardBanner: View {
    let heard: String

    /// Green for words on the box's light tint: darker than the system green, which is too pale for text there.
    static let textGreen = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.40, green: 0.84, blue: 0.50, alpha: 1)
                : NSColor(srgbRed: 0.09, green: 0.47, blue: 0.20, alpha: 1)
        })

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: EngineStepLogic.successMessage(heard: heard))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Self.textGreen)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.14), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rules and words

/// What the engine step decides and says, apart from the views.
@MainActor
enum EngineStepLogic {
    static let apple = "Your Mac has Apple's on-device speech recognition."
    static let download = "This Mac needs a small download for speech recognition."
    static let prompt = "Say your name out loud, or play a video that says it."
    static let waitingForEngine = "Starts as soon as speech recognition is ready."
    static var waitingForCall: String {
        "\(AppInfo.displayName) listens only during calls, so there is nothing to hear yet. Try it in your next call, or turn that off in Settings."
    }

    struct Summary: Equatable {
        var name: String
        var reason: String
        var isProblem = false
    }

    /// The engine that is picked, and why, in words for the user.
    static func summary(for resolution: EngineResolution?) -> Summary {
        guard let resolution else { return Summary(name: "Checking…", reason: "") }
        switch resolution {
        case .engine(let engine, _):
            return Summary(name: StatusText.engineName(engine), reason: isLocal(engine) ? download : apple)
        case .unavailable(let reason):
            return Summary(name: "No speech engine yet", reason: "\(reason) You can use the local model instead.", isProblem: true)
        }
    }

    static func isLocal(_ engine: EngineID) -> Bool {
        engine == .whisperLight || engine == .whisperBalanced
    }

    /// The local model the engine needs, if it is a local one.
    static func model(for resolution: EngineResolution?) -> WhisperModel? {
        guard case .engine(let engine, let locale) = resolution else { return nil }
        switch engine {
        case .whisperLight: return ModelCatalog.model(size: .light, localeIdentifier: locale)
        case .whisperBalanced: return ModelCatalog.model(size: .balanced, localeIdentifier: locale)
        case .appleSpeechTranscriber, .appleDictationTranscriber, .appleSFSpeech: return nil
        }
    }

    /// Whether listening can start with this engine: Apple's always can (it gets its files while it starts); a local
    /// model once it and the speech detector are on this Mac.
    static func isReady(_ resolution: EngineResolution?, installed: Set<WhisperModel>) -> Bool {
        guard let resolution else { return false }
        if case .unavailable = resolution { return false }
        guard let model = model(for: resolution) else { return true }
        return installed.contains(model) && installed.contains(.vad)
    }

    /// "Got it — heard “Bala”".
    static func successMessage(heard: String) -> String {
        "Got it — heard “\(heard)”"
    }
}
