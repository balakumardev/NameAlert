import Foundation

/// Whether another app is using the microphone, which is what a call looks like from outside.
public enum CallState: Sendable, Equatable {
    case inactive
    /// Something is recording, or was a moment ago (see `CallDetectionLogic`). The set says what: the bundle ID of
    /// each app, or `pid:<n>` for a process that has none.
    case active(Set<String>)
}

/// What Core Audio said about one of the processes connected to it, at one moment.
public struct AudioProcessSnapshot: Sendable, Equatable {
    public let pid: Int32
    /// `nil` for a process that has none.
    public let bundleID: String?
    /// Whether the process has an input stream running, that is, it is recording from a microphone.
    public let isRunningInput: Bool

    public init(pid: Int32, bundleID: String?, isRunningInput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
    }
}

/// Decides from successive looks at the audio processes whether a call is going on, meaning some other app is
/// recording from the microphone. It does not talk to Core Audio: the caller passes what it saw and when, which keeps
/// the rules testable without a microphone.
///
/// A process counts while it is recording, unless it is NameAlert itself (by process ID or bundle ID) or one of the
/// system's own listeners that record all day (`ignoredBundleIDs`). Apps are told apart by bundle ID, so the many
/// helper processes of one app are one entry; a process without a bundle ID is `pid:<n>`. Bundle IDs are compared
/// without regard to case, because Core Audio hands them over as the app spells them (Arc's helpers are
/// `company.thebrowser.browser.helper`, its app `company.thebrowser.Browser`); the sets that are reported keep the
/// case as it came.
///
/// A browser counts only after it has been recording for `browserDelay` without a break: a page that grabs the
/// microphone for a second (a voice search, a dictation button) is not a call. Everything else counts at once.
///
/// The state stays active for `grace` after the last time anything counted, with the same set, so the moment a
/// muted call lets go of the microphone, or hands it from one process to another, does not end it. The call is over
/// exactly `grace` after the last time it was seen.
public struct CallDetectionLogic: Sendable {
    /// System processes that listen all day (speech recognition, Siri, accessibility) or record for other apps
    /// (`com.apple.replayd`, the screen-recording daemon). They are never a call.
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.corespeechd", "com.apple.CoreSpeech", "com.apple.speech.recognitionserver",
        "com.apple.SpeechRecognitionCore", "com.apple.assistantd", "com.apple.Siri", "com.apple.VoiceOver",
        "com.apple.voicebankingd", "com.apple.accessibility.heard", "com.apple.audioaccessoryd",
        "com.apple.replayd",
    ]

    /// Safari and WebKit, Chrome, Firefox, Edge, Brave, Arc, Opera and Vivaldi. A bundle ID that starts with one of
    /// these is a browser, which takes in the helper processes that do the recording (`com.google.Chrome.helper`).
    /// Safari records in WebKit's own helpers (`com.apple.WebKit.GPU`), which are not under `com.apple.Safari`.
    public static let browserBundleIDPrefixes: [String] = [
        "com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    /// The two lists above in lower case, which is what bundle IDs are compared with. Made once.
    private static let ignoredLowercased = Set(ignoredBundleIDs.map { $0.lowercased() })
    private static let browserPrefixesLowercased = browserBundleIDPrefixes.map { $0.lowercased() }

    private struct Sighting: Sendable {
        var time: Date
        var apps: Set<String>
    }

    private let ownPID: Int32
    private let ownBundleIDLowercased: String
    private let browserDelay: TimeInterval
    private let grace: TimeInterval
    /// Since when each browser that is recording now has been, by bundle ID. A browser that let go is not here.
    private var browserSince: [String: Date] = [:]
    /// The last time anything counted, and what it was.
    private var lastSighting: Sighting?

    /// - Parameters:
    ///   - ownPID: The process ID of NameAlert, whose own recording is not a call.
    ///   - ownBundleID: The bundle ID of NameAlert.
    ///   - browserDelay: How long, in seconds, a browser has to be recording before it counts.
    ///   - grace: How long, in seconds, the call lasts after the last time anything counted.
    public init(ownPID: Int32, ownBundleID: String, browserDelay: TimeInterval = 3, grace: TimeInterval = 8) {
        self.ownPID = ownPID
        self.ownBundleIDLowercased = ownBundleID.lowercased()
        self.browserDelay = browserDelay
        self.grace = grace
    }

    /// Takes the next look at the audio processes, made at `now`, and returns whether a call is going on. Call it
    /// with every look, in order: the browser delay and the grace are measured between the looks.
    ///
    /// A clock that was set back must not hold a call open, or keep a browser waiting, until it catches up. So the
    /// times that were remembered count as no later than `now`: the delay and the grace start again from there.
    public mutating func update(processes: [AudioProcessSnapshot], now: Date) -> CallState {
        var counting: Set<String> = []
        var browsers: [String: Date] = [:]
        for process in processes where process.isRunningInput && process.pid != ownPID {
            guard let bundleID = process.bundleID, !bundleID.isEmpty else {
                counting.insert("pid:\(process.pid)")
                continue
            }
            let lowercased = bundleID.lowercased()
            if lowercased == ownBundleIDLowercased || Self.ignoredLowercased.contains(lowercased) { continue }
            guard Self.isBrowser(lowercased) else {
                counting.insert(bundleID)
                continue
            }
            let since = min(browserSince[bundleID] ?? now, now)
            browsers[bundleID] = since
            if now.timeIntervalSince(since) >= browserDelay { counting.insert(bundleID) }
        }
        // Only the browsers that are recording now stay: one that let go starts its delay again when it comes back.
        browserSince = browsers

        if !counting.isEmpty {
            lastSighting = Sighting(time: now, apps: counting)
            return .active(counting)
        }
        if var sighting = lastSighting {
            sighting.time = min(sighting.time, now)
            if now.timeIntervalSince(sighting.time) < grace {
                lastSighting = sighting
                return .active(sighting.apps)
            }
            lastSighting = nil
        }
        return .inactive
    }

    /// Whether a bundle ID, already in lower case, starts with the ID of a browser.
    private static func isBrowser(_ lowercasedBundleID: String) -> Bool {
        browserPrefixesLowercased.contains { lowercasedBundleID.hasPrefix($0) }
    }
}
