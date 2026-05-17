import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: ListeningEngine

    var body: some View {
        TabView {
            GeneralTab(settings: settings, engine: engine)
                .tabItem { Label("General", systemImage: "gear") }
            KeywordsTab(settings: settings, engine: engine)
                .tabItem { Label("Keywords", systemImage: "text.magnifyingglass") }
            AlertsTab(settings: settings, engine: engine)
                .tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(width: 520, height: 460)
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engine: ListeningEngine

    var body: some View {
        Form {
            Section("Status") {
                HStack {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                    Spacer()
                    Button(engine.status == .listening ? "Pause" : "Start") {
                        Task { await engine.toggle() }
                    }
                }
                if !engine.lastTranscript.isEmpty {
                    LabeledContent("Last transcript") {
                        Text(engine.lastTranscript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                if let hit = engine.lastHit {
                    LabeledContent("Last hit") {
                        Text("\(hit.keyword) — \(hit.matchedText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Audio Source") {
                Picker("Listen to", selection: Binding(
                    get: { settings.audioSource },
                    set: { settings.audioSource = $0 }
                )) {
                    ForEach(AudioSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.audioSource) { _, _ in
                    Task {
                        await engine.refreshConfiguration()
                        if engine.status == .listening || engine.status == .downloadingModel {
                            await engine.stop()
                            await engine.start()
                        }
                    }
                }
                Text(settings.audioSource == .systemAudio
                     ? "Captures audio playing through your speakers (Zoom, Teams, YouTube). Requires Screen Recording permission."
                     : "Captures your default microphone input. Requires Microphone permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Start listening on launch", isOn: $settings.listenAtLaunch)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusIcon: String {
        switch engine.status {
        case .listening: return "ear.and.waveform"
        case .downloadingModel: return "arrow.down.circle"
        case .requestingPermission: return "lock"
        case .error: return "exclamationmark.triangle"
        case .stopped: return "pause.circle"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .listening: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    private var statusText: String {
        switch engine.status {
        case .stopped: return "Paused"
        case .requestingPermission: return "Requesting permissions…"
        case .downloadingModel: return "Preparing speech model…"
        case .listening: return "Listening"
        case .error(let message): return "Error: \(message)"
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }
}
