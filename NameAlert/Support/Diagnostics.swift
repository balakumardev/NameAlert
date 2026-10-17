import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import NameAlertSpeech

/// The text "Copy Diagnostics" puts on the pasteboard, for a support request: which version of what is running, on
/// which Mac, what it is doing, how it is set up, and what it logged during this run.
///
/// It holds no words you listen for, no rule names, no addresses and no secrets, and nothing that was heard: the set-up
/// and what the app has done are told in counts and yes or no, and the log is only what the app itself wrote at the
/// info level or above, less the lines `AppLogCollector` leaves out by rule (transcript text is only ever logged as a
/// debug line, which is neither kept nor read).
///
/// The same facts, as a `ProblemReportEnvironment`, head a problem report (`environment(for:)`).
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
        /// What the app has done since it started, in counts.
        var activity = Activity()
        /// This run's log lines, or the one line that says why they could not be read.
        var log: [String]
    }

    /// What the app has done since it started: counts, and the short description (error domain and code) of the last
    /// failed save. Nothing that was heard, no names, no addresses.
    struct Activity: Equatable {
        var runtime: RuntimeStats
        var dispatch: DispatchStats
        var configSaveError: String?
        var historySaveError: String?

        init(
            runtime: RuntimeStats = RuntimeStats(), dispatch: DispatchStats = DispatchStats(),
            configSaveError: String? = nil, historySaveError: String? = nil
        ) {
            self.runtime = runtime
            self.dispatch = dispatch
            self.configSaveError = configSaveError
            self.historySaveError = historySaveError
        }
    }

    // MARK: Gathering

    /// The report for what the app is doing now.
    @MainActor
    static func report(for controller: ListeningController, now: Date = Date()) async -> String {
        let resolution = await controller.resolvedEngine()
        let log = await logLines()
        let snapshot = Snapshot(
            appName: AppInfo.displayName, version: AppInfo.version, build: AppInfo.build,
            macOS: osVersionText, architecture: architecture, date: now,
            state: StatusText.title(for: controller.state, now: now),
            engine: engineText(for: resolution), permissions: controller.permissions,
            warnings: controller.warnings.map(warningText).sorted(),
            installedModels: controller.installedModels.map(\.rawValue).sorted(),
            configuration: controller.configuration, activity: await activity(for: controller), log: log)
        return format(snapshot)
    }

    /// What the problem report's `environment` says: this install and this Mac, never a word, rule, address or secret.
    @MainActor
    static func environment(for controller: ListeningController) async -> ProblemReportEnvironment {
        let resolution = await controller.resolvedEngine()
        return ProblemReportEnvironment(
            appVersion: AppInfo.version, build: AppInfo.build, macOSVersion: osVersionText, macModel: macModel,
            architecture: architecture, engine: engineText(for: resolution), locale: Locale.current.identifier,
            listeningSource: controller.configuration.listening.source.rawValue)
    }

    /// The counts the controller and the dispatcher keep, and the last failed saves.
    @MainActor
    static func activity(for controller: ListeningController) async -> Activity {
        let errors = await controller.lastSaveErrors()
        return Activity(
            runtime: controller.runtimeStats, dispatch: await controller.dispatchStats(),
            configSaveError: errors.config, historySaveError: errors.history)
    }

    /// "26.0.1".
    static var osVersionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The Mac's model identifier from `hw.model`, for example "Mac15,3"; "unknown" when it cannot be read.
    static var macModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
        lines.append("Since the app started (counts only)")
        lines.append(contentsOf: activityLines(snapshot.activity).map { "  " + $0 })
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

    /// What the app has done, in counts. Channels are named by kind (ntfy, Webhook), never by address.
    static func activityLines(_ activity: Activity) -> [String] {
        let runtime = activity.runtime
        let dispatch = activity.dispatch
        func perChannel(_ counts: [ChannelKind: Int]) -> String {
            let parts = ChannelKind.allCases.compactMap { kind in
                counts[kind].map { "\(kind.displayName) \($0)" }
            }
            return parts.isEmpty ? "none" : parts.joined(separator: ", ")
        }
        return [
            "Listening sessions started: \(runtime.sessionsStarted)",
            "Listening attempts that failed and were retried: \(runtime.transientFailures) (in a row now: \(runtime.currentFailureStreak))",
            "Times the local model fell behind: \(runtime.fallingBehindReports)",
            "Hits let through: \(dispatch.admitted); held back by the wait between alerts: \(dispatch.heldByCooldown)",
            "Deliveries started: \(runtime.deliveriesStarted), under way: \(runtime.deliveriesUnderWay), cancelled: \(dispatch.cancelled)",
            "Delivered: \(perChannel(dispatch.deliveredByChannel))",
            "Failed: \(perChannel(dispatch.failedByChannel))",
            "Last failed save of settings: \(activity.configSaveError ?? "none")",
            "Last failed save of history: \(activity.historySaveError ?? "none")",
        ]
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

    /// This run's log lines, oldest first, at most `limit`: what `AppLogCollector` lets through, one line each. When the
    /// store cannot be read, the one line that says so.
    static func logLines(limit: Int = logLineLimit) async -> [String] {
        switch await AppLogCollector.lines(limit: limit) {
        case .success(let lines): AppLogCollector.reportLines(from: lines)
        case .failure(let failure): ["The log could not be read: \(failure.description)"]
        }
    }

    /// One log entry on one line.
    static func logLine(date: Date, tag: String, category: String, message: String) -> String {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let text = flat.count > logLineLength ? String(flat.prefix(logLineLength)) + "…" : flat
        return "\(date.formatted(.iso8601)) \(tag) [\(category)] \(text)"
    }
}
