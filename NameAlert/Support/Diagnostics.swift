import Foundation
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech
import OSLog

/// The text "Copy Diagnostics" puts on the pasteboard, for a support request: which version of what is running, on
/// which Mac, what it is doing, how it is set up, and what it logged during this run.
///
/// It holds no words you listen for, no rule names, no addresses and no secrets, and nothing that was heard: the set-up
/// is told in counts and yes or no, and the log is only what the app itself wrote at the info level or above
/// (transcript text is only ever logged as a private debug line, which is neither kept nor read).
enum Diagnostics {
    /// The subsystem the app logs under.
    static let subsystem = "dev.balakumar.namealert"

    /// The most log lines a report holds: the latest ones.
    static let logLineLimit = 200

    /// The longest a log line may be before it is cut.
    private static let logLineLength = 400

    /// Everything a report says, gathered. `format(_:)` turns it into text.
    struct Snapshot {
        var appName: String
        var version: String
        var build: String
        var macOS: String
        var architecture: String
        var date: Date
        var state: String
        var engine: String
        var permissions: PermissionsSnapshot
        var warnings: [String]
        var installedModels: [String]
        var configuration: AppConfiguration
        /// This run's log lines, or the one line that says why they could not be read.
        var log: [String]
    }

    // MARK: Gathering

    /// The report for what the app is doing now.
    @MainActor
    static func report(for controller: ListeningController, now: Date = Date()) async -> String {
        let resolution = await controller.resolvedEngine()
        let log = await logLines()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let snapshot = Snapshot(
            appName: AppInfo.displayName, version: AppInfo.version, build: AppInfo.build,
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture, date: now, state: StatusText.title(for: controller.state, now: now),
            engine: engineText(for: resolution), permissions: controller.permissions,
            warnings: controller.warnings.map(warningText).sorted(),
            installedModels: controller.installedModels.map(\.rawValue).sorted(),
            configuration: controller.configuration, log: log)
        return format(snapshot)
    }

    /// The architecture this copy of the app runs as.
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    @MainActor
    static func engineText(for resolution: EngineResolution) -> String {
        switch resolution {
        case .engine(let engine, let locale): "\(StatusText.engineName(engine)), \(locale)"
        case .unavailable(let reason): "none (\(reason))"
        }
    }

    static func warningText(_ warning: RuntimeWarning) -> String {
        switch warning {
        case .localModelFallingBehind: "local model falling behind"
        case .screenRecordingNeedsRelaunch: "Screen Recording needs a relaunch"
        }
    }

    // MARK: Formatting

    /// The report as plain text. Pure: the same snapshot gives the same text.
    static func format(_ snapshot: Snapshot) -> String {
        let permissions = PermissionKind.allCases
            .map { "\(permissionName($0)) \(permissionWord(snapshot.permissions[$0]))" }
            .joined(separator: ", ")
        let warnings = snapshot.warnings.isEmpty ? "none" : snapshot.warnings.joined(separator: ", ")
        let models = snapshot.installedModels.isEmpty ? "none" : snapshot.installedModels.joined(separator: ", ")

        var lines: [String] = []
        lines.append("\(snapshot.appName) \(snapshot.version) (\(snapshot.build))")
        lines.append("macOS \(snapshot.macOS), \(snapshot.architecture)")
        lines.append("Date: \(snapshot.date.formatted(.iso8601))")
        lines.append("")
        lines.append("State: \(snapshot.state)")
        lines.append("Speech engine: \(snapshot.engine)")
        lines.append("Permissions: \(permissions)")
        lines.append("Warnings: \(warnings)")
        lines.append("Models on this Mac: \(models)")
        lines.append("")
        lines.append("Set-up (counts only)")
        lines.append(contentsOf: setUp(snapshot.configuration).map { "  " + $0 })
        lines.append("")
        lines.append("Log, this run (\(snapshot.log.count) lines)")
        lines.append(contentsOf: snapshot.log.map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    /// How the app is set up, without any word, name, address or secret.
    static func setUp(_ configuration: AppConfiguration) -> [String] {
        let rules = configuration.rules
        let enabled = rules.filter(\.isEnabled).count
        var words = 0
        for rule in rules {
            words += rule.terms.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
        var used: [String] = []
        for kind in ChannelKind.allCases {
            let count = rules.filter { $0.channels.contains(kind) }.count
            if count > 0 { used.append("\(kind.displayName) \(count)") }
        }
        var language = "system default"
        if let identifier = configuration.speech.localeIdentifier, !identifier.isEmpty { language = identifier }
        let network: [ChannelKind] = [.ntfy, .telegramCall, .webhook]
        let setUpNetwork = network
            .map { "\($0.displayName) \(yesNo(configuration.channels.isConfigured($0)))" }
            .joined(separator: ", ")

        let listening = configuration.listening
        let speech = configuration.speech
        var lines: [String] = []
        lines.append("Setup finished: \(yesNo(configuration.hasCompletedOnboarding))")
        lines.append("Listens to: \(listening.source.rawValue), \(listening.mode.rawValue)")
        lines.append("Starts at launch: \(yesNo(listening.startOnLaunch))")
        lines.append("Open at login: \(yesNo(configuration.general.launchAtLogin))")
        lines.append("Engine choice: \(speech.engine.rawValue), local model \(speech.localModelSize.rawValue), language \(language)")
        lines.append("Rules: \(rules.count) (\(enabled) on), \(words) words in all")
        lines.append("Alerts the rules use: \(used.isEmpty ? "none" : used.joined(separator: ", "))")
        lines.append("Alerts set up: \(setUpNetwork)")
        lines.append("Wait between any two alerts: \(Int(configuration.globalCooldownSeconds)) s")
        lines.append("History: \(configuration.history.isEnabled ? "on" : "off")")
        return lines
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func permissionName(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .speechRecognition: "Speech Recognition"
        case .notifications: "Notifications"
        }
    }

    private static func permissionWord(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "allowed"
        case .denied: "denied"
        case .notDetermined: "not decided"
        }
    }

    // MARK: The log

    /// This run's log lines from `OSLogStore`, oldest first, at most `limit`. When the store cannot be read, the one
    /// line that says so.
    static func logLines(limit: Int = logLineLimit) async -> [String] {
        // Reading the store takes a moment: not on the main thread.
        await Task.detached(priority: .utility) { readLog(limit: limit) }.value
    }

    private static func readLog(limit: Int) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0), matching: predicate)
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                guard let tag = levelTag(entry.level) else { continue }
                lines.append(logLine(date: entry.date, tag: tag, category: entry.category, message: entry.composedMessage))
            }
            return Array(lines.suffix(limit))
        } catch {
            return ["The log could not be read: \(error.localizedDescription)"]
        }
    }

    /// The word for a level, or `nil` for the ones left out: debug lines are the only place heard text may be logged.
    private static func levelTag(_ level: OSLogEntryLog.Level) -> String? {
        switch level {
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .debug, .undefined: nil
        @unknown default: nil
        }
    }

    /// One log entry on one line.
    static func logLine(date: Date, tag: String, category: String, message: String) -> String {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let text = flat.count > logLineLength ? String(flat.prefix(logLineLength)) + "…" : flat
        return "\(date.formatted(.iso8601)) \(tag) [\(category)] \(text)"
    }
}
