import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Makes the form's model each time the window is asked for (a closed `Window` keeps its views), so each report starts
/// empty.
struct ReportProblemWindowContent: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @State private var model: ReportProblemModel?

    var body: some View {
        Group {
            if let model {
                ReportProblemView(model: model)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: ReportProblemView.contentSize.width, height: ReportProblemView.contentSize.height)
        .task(id: router.reportProblemRequests) {
            model = nil
            model = ReportProblemModel(environment: await Diagnostics.environment(for: controller))
        }
    }
}

/// The Report a Problem window: what happened, what to include, a preview of the exact text, and Copy Report & Open
/// Email. Opened from the menu bar and from About.
struct ReportProblemView: View {
    static let contentSize = CGSize(width: 560, height: 640)

    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var model: ReportProblemModel
    @FocusState private var messageFocused: Bool

    init(model: ReportProblemModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if model.state == .copied { copiedView } else { formView }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private var formView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    messageField
                    includeCard
                    preview
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(verbatim: ReportProblemCopy.handoff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(ReportProblemCopy.copyAndEmail) { model.copyAndOpenEmail() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canCopy)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onAppear { messageFocused = true }
        .onChange(of: model.includeLogs) { Task { await model.logsToggled() } }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: ReportProblemCopy.messageLabel).font(.callout.weight(.medium))
            TextEditor(text: $model.message)
                .scrollContentBackground(.hidden)
                .focused($messageFocused)
                .padding(6)
                .frame(height: 112)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityLabel(ReportProblemCopy.messageLabel)
            Text(verbatim: messageHint ?? " ")
                .font(.caption)
                .foregroundStyle(model.messageIsTooLong ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }

    private var messageHint: String? {
        if model.messageIsTooLong { return ReportProblemCopy.tooLong }
        if model.messageIsTooShort { return ReportProblemCopy.tooShort }
        return nil
    }

    private var includeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.includeDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ReportProblemCopy.diagnosticsToggle)
                    SettingsCaption(ReportProblemCopy.diagnosticsDetail)
                }
            }
            Divider()
            Toggle(isOn: $model.includeLogs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ReportProblemCopy.logsToggle)
                    SettingsCaption(ReportProblemCopy.logsDetail)
                }
            }
            if model.isLoadingLogs {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: ReportProblemCopy.collectingLogs).font(.caption).foregroundStyle(.secondary)
                }
            } else if model.includeLogs && model.logsUnavailable {
                SettingsCaption(ReportProblemCopy.noLogs)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: ReportProblemCopy.previewLabel).font(.callout.weight(.medium))
            ScrollView {
                Text(verbatim: model.previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 170)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            .accessibilityLabel("The report that will be copied")
        }
    }

    private var copiedView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: ReportProblemCopy.copied).font(.headline)
            Text(verbatim: ReportProblemCopy.copiedDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(ReportProblemCopy.close) { dismissWindow(id: WindowID.reportProblem) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(24)
    }
}
