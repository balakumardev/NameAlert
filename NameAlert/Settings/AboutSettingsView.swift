import AppKit
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// Settings → About: the app and its version, what it does with your audio, where to get help, a report to send when
/// something is wrong, running setup again, and the licenses of what it is built with.
struct AboutSettingsView: View {
    @Environment(ListeningController.self) private var controller
    @Environment(WindowRouter.self) private var router
    @Environment(UpdateCheckCoordinator.self) private var updates: UpdateCheckCoordinator?

    @State private var copy: CopyState = .idle
    @State private var offersCrashReports = CrashReportPreferences.standard.offerToSend
    @State private var checksForUpdates = UpdateCheckPreferences(defaults: .standard).isEnabled
    @State private var isShowingAcknowledgements: Bool
    @State private var acknowledgements: String?

    /// `showsAcknowledgements` opens the licenses from the start, for renders.
    init(showsAcknowledgements: Bool = false) {
        _isShowingAcknowledgements = State(initialValue: showsAcknowledgements)
    }

    /// What the summary of privacy says: the audio stays, and what can leave is named, with where it goes.
    static let privacySummary =
        "Audio never leaves this Mac. The words around a mention leave only if you set up ntfy, a Telegram call or a webhook — and only to the service you chose."

    var body: some View {
        Form {
            Section {
                hero
            }

            Section {
                Link("Support", destination: AboutLinks.support)
                    .foregroundStyle(.tint)
                Link("Privacy", destination: AboutLinks.privacy)
                    .foregroundStyle(.tint)
            } header: {
                SettingsSectionTitle("Help")
            }

            if let updates, updates.isAvailable {
                Section {
                    updateChecks(updates)
                } header: {
                    SettingsSectionTitle("Updates")
                }
            }

            Section {
                copyDiagnostics
                reportProblem
                crashReports
                setupAgain
            } header: {
                SettingsSectionTitle("Troubleshooting")
            }

            Section {
                DisclosureGroup("Acknowledgements", isExpanded: $isShowingAcknowledgements) {
                    ScrollView {
                        Text(verbatim: acknowledgements ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 200)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Acknowledgements text")
                }
            } footer: {
                SettingsCaption("whisper.cpp, the Whisper model weights, Silero VAD and the SCOWL word lists.")
            }
        }
        .formStyle(.grouped)
        .task(id: isShowingAcknowledgements) {
            if isShowingAcknowledgements, acknowledgements == nil { acknowledgements = AboutLinks.acknowledgements() }
        }
    }

    // MARK: Parts

    private var hero: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text(verbatim: AppInfo.displayName)
                .font(.title2.bold())
            Text(verbatim: Self.versionLine(version: AppInfo.version, build: AppInfo.build))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: Self.privacySummary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var copyDiagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button("Copy Diagnostics", action: copyReport)
                    .disabled(copy == .working)
                    .accessibilityLabel("Copy diagnostics")
                if copy == .copied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            SettingsCaption(
                "Copies the version, this Mac, what \(AppInfo.displayName) is doing and this session's log, for a support request. It has no keywords, secrets or anything that was heard.")
        }
    }

    private var reportProblem: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Report a Problem…") { router.open(.reportProblem) }
                .accessibilityLabel("Report a problem")
            SettingsCaption(
                "Write what went wrong, see exactly what the report holds, then copy it and email it. Nothing is sent from the app.")
        }
    }

    private var crashReports: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                CrashReportCopy.settingTitle,
                isOn: Binding(get: { offersCrashReports }, set: setOffersCrashReports)
            )
            .accessibilityLabel("Offer crash reports")
            SettingsCaption(CrashReportCopy.settingDetail)
        }
    }

    /// The switch for the daily App Store check, what that check asks and sends, and a button for checking now. The
    /// section exists only in the App Store build: no other build checks.
    private func updateChecks(_ updates: UpdateCheckCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    UpdateCheckCopy.aboutToggleTitle,
                    isOn: Binding(get: { checksForUpdates }, set: setChecksForUpdates)
                )
                .accessibilityLabel("Check for updates automatically")
                SettingsCaption(UpdateCheckCopy.aboutToggleDetail)
            }
            HStack(spacing: 12) {
                Button(UpdateCheckCopy.aboutCheckButton) { Task { await updates.checkManually() } }
                    .accessibilityLabel("Check for updates now")
                Text(verbatim: UpdateCheckCopy.lastChecked(updates.lastCheckDate, now: Date()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupAgain: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Run Setup Again", action: runSetupAgain)
                .accessibilityLabel("Run setup again")
            SettingsCaption("Goes through the first-time steps again.")
        }
    }

    // MARK: Actions

    private func copyReport() {
        copy = .working
        Task {
            let report = await Diagnostics.report(for: controller)
            Pasteboard.copy(report)
            copy = .copied
            AccessibilityNotification.Announcement("Diagnostics copied").post()
            try? await Task.sleep(for: .seconds(3))
            copy = .idle
        }
    }

    /// Turning the offer off also deletes the crash reports kept so far: nobody is going to be asked about them.
    private func setOffersCrashReports(_ isOn: Bool) {
        offersCrashReports = isOn
        CrashReportPreferences.standard.offerToSend = isOn
        if !isOn { PendingCrashReportStore.standard.removeAll() }
    }

    private func setChecksForUpdates(_ isOn: Bool) {
        checksForUpdates = isOn
        UpdateCheckPreferences(defaults: .standard).isEnabled = isOn
    }

    private func runSetupAgain() {
        Self.runSetupAgain(controller: controller, router: router)
    }

    /// Marks setup as not done and opens it. Leaving it half-way brings it back at the next launch.
    static func runSetupAgain(controller: ListeningController, router: WindowRouter) {
        controller.edit { $0.hasCompletedOnboarding = false }
        router.open(.onboarding)
    }

    enum CopyState: Equatable {
        case idle, working, copied
    }

    // MARK: Words

    /// "Version 1.0.0 (123)".
    static func versionLine(version: String, build: String) -> String {
        "Version \(version) (\(build))"
    }
}

/// The addresses About links to, and the licenses text it shows.
enum AboutLinks {
    static let support = address("https://balakumardev.github.io/NameAlert/support.html")
    static let privacy = address("https://balakumardev.github.io/NameAlert/privacy.html")
    /// Apple's standard license for App Store apps: the Terms of Use of Pro.
    static let terms = address("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    private static func address(_ text: String) -> URL {
        // A fixed address: the tests read each one back.
        URL(string: text) ?? URL(fileURLWithPath: "/")
    }

    /// The licenses of what the app is built with, from the file in the app. A sentence when it cannot be read.
    static func acknowledgements(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The acknowledgements could not be loaded." }
        return text
    }
}
