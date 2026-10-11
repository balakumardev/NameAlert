import NameAlertCore
import SwiftUI

/// Step 4: the name to listen for, other ways it may be spelled, how closely to match and how to be alerted. It
/// becomes the rule "My name".
struct NameStep: View {
    @Bindable var model: OnboardingModel
    /// Called when Return is pressed in the name field.
    var submit: () -> Void

    @FocusState private var isNameFocused: Bool
    @FocusState private var areVariantsFocused: Bool

    static let variantsPrompt = "Nicknames or spellings, e.g. Bala, Balakumar"
    static let alertQuestion = "How should we alert you?"
    static let laterNote = "ntfy, Telegram and webhook alerts can be set up later in Settings."

    var body: some View {
        OnboardingStepLayout(title: "What should \(AppInfo.displayName) listen for?") {
            VStack(alignment: .leading, spacing: 14) {
                labeled("Your name") {
                    TextField("Your name", text: $model.name, prompt: Text("Your first name or a nickname").foregroundStyle(.secondary))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($isNameFocused)
                        .onSubmit(submit)
                        .accessibilityLabel("Your name")
                }

                labeled("Also listen for (optional)") {
                    TermChipsField(
                        terms: model.variants, focus: $areVariantsFocused,
                        add: { new in addVariants(new) },
                        remove: { term in model.variants.removeAll { $0 == term } },
                        emptyPrompt: Self.variantsPrompt)
                }

                // Each on a row of its own: the three-part Sensitivity picker needs about 240 points, more than a column
                // beside the alert choices has.
                sensitivity

                alerts
            }
        }
        .task {
            // The field is not there to take the keyboard until the step has been built.
            try? await Task.sleep(for: .milliseconds(150))
            isNameFocused = true
        }
    }

    // MARK: Parts

    private func labeled<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.callout)
                .foregroundStyle(.secondary)
            field()
        }
    }

    private var sensitivity: some View {
        labeled("Sensitivity") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Sensitivity", selection: $model.sensitivity) {
                    ForEach(Sensitivity.allCases, id: \.self) { level in
                        Text(verbatim: RuleEditorView.title(for: level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Sensitivity")
                SettingsCaption(RuleEditorView.explanation(for: model.sensitivity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var alerts: some View {
        labeled(Self.alertQuestion) {
            VStack(alignment: .leading, spacing: 6) {
                // Two columns, filled top to bottom: Sound and Notification, then the alarm and the flash.
                HStack(alignment: .top, spacing: 16) {
                    channelColumn(Array(OnboardingModel.offeredChannels.prefix(2)))
                    channelColumn(Array(OnboardingModel.offeredChannels.dropFirst(2)))
                }
                SettingsCaption(Self.laterNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func channelColumn(_ kinds: [ChannelKind]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                channelToggle(kind)
            }
        }
    }

    private func channelToggle(_ kind: ChannelKind) -> some View {
        Toggle(
            kind.displayName,
            isOn: Binding(get: { model.channels.contains(kind) }, set: { model.setChannel(kind, isOn: $0) })
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel("Alert with \(kind.displayName)")
    }

    /// Adds nicknames, leaving out the name itself and any that are there already.
    private func addVariants(_ new: [String]) {
        let name = model.trimmedName.lowercased()
        let known = Set(model.variants.map { $0.lowercased() })
        for word in new where word.lowercased() != name && !known.contains(word.lowercased()) {
            model.variants.append(word)
        }
    }
}
