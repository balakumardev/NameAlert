import AppKit
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Makes the crash report window's model each time the window is asked for (a closed `Window` keeps its views), after
/// reading the environment of the report.
struct CrashReportWindowContent: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @State private var model: CrashReportModel?

    var body: some View {
        Group {
            if let model {
                CrashReportView(model: model)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: CrashReportView.contentSize.width, height: CrashReportView.contentSize.height)
        .task(id: router.crashReportRequests) {
            model = nil
            let environment = await Diagnostics.environment(for: controller)
            model = CrashReportModel(store: .standard, preferences: .standard, environment: environment)
        }
    }
}

/// The "Takeheed quit unexpectedly last time" window: what a crash report holds, an optional note, the exact report
/// behind a disclosure, "Don't ask again", and Copy Report & Open Email or Don't Send. Opened by
/// `CrashReportPromptCoordinator`.
///
/// Closing the window without choosing keeps the crash files, so the offer comes back at the next launch. Neither button
/// is the default one: the window opens by itself a couple of seconds after launch, and a Return meant for something
/// else must not copy or delete anything.
struct CrashReportView: View {
    static let contentSize = CGSize(width: 540, height: 520)

    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var model: CrashReportModel
    @State private var previewExpanded: Bool

    init(model: CrashReportModel, previewExpanded: Bool = false) {
        self.model = model
        _previewExpanded = State(initialValue: previewExpanded)
    }

    var body: some View {
        Group {
            if model.reports.isEmpty {
                // Nothing waits (another window dealt with it): close without a flash of form.
                Color.clear.onAppear { dismissWindow(id: WindowID.crashReport) }
            } else if model.state == .copied {
                copiedView
            } else {
                formView
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private var formView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    noteField
                    previewDisclosure
                }
                .padding(24)
            }
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(verbatim: CrashReportCopy.heading)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            Text(verbatim: CrashReportCopy.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let waiting = CrashReportCopy.waiting(count: model.reports.count) {
                Text(verbatim: waiting)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: CrashReportCopy.noteLabel).font(.callout.weight(.medium))
            TextEditor(text: $model.note)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 84)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityLabel(CrashReportCopy.noteLabel)
            Text(verbatim: model.noteIsTooLong ? CrashReportCopy.tooLong : " ")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var previewDisclosure: some View {
        DisclosureGroup(CrashReportCopy.disclosure, isExpanded: $previewExpanded) {
            // Only built while open: the text is large with several crashes.
            if previewExpanded {
                ScrollView {
                    Text(verbatim: model.previewText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 180)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .accessibilityLabel("The crash report")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(CrashReportCopy.dontAskAgain, isOn: $model.dontAskAgain)
                .toggleStyle(.checkbox)
                .fixedSize()
            Spacer(minLength: 12)
            Button(CrashReportCopy.dontSend) {
                model.dontSend()
                dismissWindow(id: WindowID.crashReport)
            }
            .controlSize(.large)
            Button(CrashReportCopy.copyAndEmail) { model.copyAndOpenEmail() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCopy)
        }
    }

    private var copiedView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: CrashReportCopy.copied).font(.headline)
            Text(verbatim: CrashReportCopy.copiedDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(CrashReportCopy.close) { dismissWindow(id: WindowID.crashReport) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(24)
    }
}
