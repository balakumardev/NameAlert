import NameAlertCore
import SwiftUI

/// Step 2: what to listen to. Three cards, and "Only during calls" where this Mac can tell when a call is going on.
struct SourceStep: View {
    @Bindable var model: OnboardingModel

    @Environment(\.callDetectionSupported) private var callDetectionSupported

    /// The cards, left to right.
    static let sources: [AudioSourceKind] = [.systemAudio, .microphone, .both]

    var body: some View {
        OnboardingStepLayout(title: "Choose what to listen to", subtitle: "You can change this any time in Settings.") {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    ForEach(Self.sources, id: \.self) { source in
                        SourceCard(source: source, isSelected: model.source == source) { model.source = source }
                    }
                }
                if callDetectionSupported {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only during calls")
                            SettingsCaption(
                                GeneralSettingsView.explanation(for: .duringCalls, callDetectionSupported: true))
                        }
                        Toggle("Only during calls", isOn: $model.onlyDuringCalls)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("Only during calls")
                    }
                }
            }
        }
    }

    // MARK: Words

    static func description(for source: AudioSourceKind) -> String {
        switch source {
        case .systemAudio: "Calls, meetings and videos playing on this Mac."
        case .microphone: "People talking in the room."
        case .both: "This Mac and the people around you."
        }
    }

    static func symbols(for source: AudioSourceKind) -> [String] {
        switch source {
        case .systemAudio: ["speaker.wave.2.fill"]
        case .microphone: ["mic.fill"]
        case .both: ["speaker.wave.2.fill", "mic.fill"]
        }
    }
}

/// One way of listening, as a card that can be chosen.
private struct SourceCard: View {
    let source: AudioSourceKind
    let isSelected: Bool
    let choose: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let title = GeneralSettingsView.title(for: source)
        let description = SourceStep.description(for: source)
        Button(action: choose) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(SourceStep.symbols(for: source), id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
                .frame(height: 32)
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)),
                in: .rect(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderStyle, lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .padding(8)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        return contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator)
    }
}
