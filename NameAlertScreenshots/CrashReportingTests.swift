import Foundation
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import Testing

@testable import ScreenshotHost

/// A folder and a defaults domain of their own for one test, and what to make crashes with.
private struct Scratch {
    let directory: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ScratchFailure.noSuite }
        self.defaults = defaults
    }

    var preferences: CrashReportPreferences { CrashReportPreferences(defaults: defaults) }

    func makeStore() -> PendingCrashReportStore {
        PendingCrashReportStore(directory: directory, ownBinaries: ["Takeheed"])
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    enum ScratchFailure: Error { case noSuite }

    static let fallback = CrashVersionInfo(appVersion: "1.0.0", build: "1", osVersion: "27.0")

    /// A MetricKit-shaped crash whose `terminationReason` is `padding` long: `distinct` makes each one its own report.
    static func crash(distinct: Int, padding: Int = 0) -> Data {
        let object: [String: Any] = [
            "diagnosticMetaData": [
                "exceptionType": 1, "signal": 6, "appVersion": "1.0.0",
                "terminationReason": "crash \(distinct) " + String(repeating: "x", count: padding),
            ],
            "callStackTree": [
                "callStacks": [
                    [
                        "threadAttributed": true,
                        "callStackRootFrames": [["binaryName": "Takeheed", "offsetIntoBinaryTextSegment": distinct, "address": 1]],
                    ]
                ],
                "callStackPerThread": false,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static let environment = ProblemReportEnvironment(
        appVersion: "1.0.0", build: "1", macOSVersion: "27.0.0", macModel: "Mac16,1", architecture: "arm64",
        engine: "Apple Speech", locale: "en_US", listeningSource: "system")
}

@Suite("Crash reports")
@MainActor
struct CrashReportingTests {
    // MARK: Collector

    @Test("The collector keeps crashes only while the offer is on")
    func collectorKeepsOnlyWhenOffered() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        let collector = CrashDiagnosticsCollector(
            store: store, preferences: scratch.preferences, fallback: { Scratch.fallback }, subscribe: { _ in })

        scratch.preferences.offerToSend = false
        collector.handle([(json: Scratch.crash(distinct: 1), crashedAt: Date())])
        #expect(store.pending().isEmpty, "the offer is off: nothing is kept")

        scratch.preferences.offerToSend = true
        collector.handle([(json: Scratch.crash(distinct: 2), crashedAt: Date())])
        #expect(store.pending().count == 1)
    }

    @Test("Starting with the offer off deletes what was kept; the collector subscribes once")
    func collectorStartClearsWhenOff() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        #expect(store.pending().count == 1)

        scratch.preferences.offerToSend = false
        let subscriptions = Counter()
        let collector = CrashDiagnosticsCollector(
            store: store, preferences: scratch.preferences, fallback: { Scratch.fallback },
            subscribe: { _ in subscriptions.increment() })
        collector.start()
        collector.start()
        #expect(store.pending().isEmpty)
        #expect(subscriptions.value == 1)
    }

    @Test("A delivery that kept a crash tells the prompt; one that kept none does not")
    func collectorTellsThePrompt() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let told = Counter()
        let collector = CrashDiagnosticsCollector(
            store: scratch.makeStore(), preferences: scratch.preferences, fallback: { Scratch.fallback },
            subscribe: { _ in })
        collector.onNewReports = { told.increment() }
        collector.handle([(json: Data("not json".utf8), crashedAt: Date())])
        collector.handle([(json: Scratch.crash(distinct: 3), crashedAt: Date())])
        try await Task.sleep(for: .milliseconds(200))
        #expect(told.value == 1)
    }

    // MARK: Prompt

    @Test("The prompt stays closed with nothing pending, or with the offer off")
    func promptNeedsPendingAndOffer() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        let opened = Counter()
        let coordinator = CrashReportPromptCoordinator(
            store: store, preferences: scratch.preferences, isBusy: { false }, openWindow: { opened.increment() })
        coordinator.evaluate()
        #expect(opened.value == 0, "nothing is pending")

        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        scratch.preferences.offerToSend = false
        coordinator.evaluate()
        #expect(opened.value == 0, "the offer is off")

        scratch.preferences.offerToSend = true
        coordinator.evaluate()
        #expect(opened.value == 1)
        coordinator.evaluate()
        #expect(opened.value == 1, "once per run")
    }

    @Test("The prompt waits while listening is starting up, then opens")
    func promptWaitsWhileBusy() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        let opened = Counter()
        let busy = Flag(true)
        let coordinator = CrashReportPromptCoordinator(
            store: store, preferences: scratch.preferences, isBusy: { busy.value },
            openWindow: { opened.increment() }, launchDelay: .milliseconds(10), retryDelay: .milliseconds(20))
        coordinator.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(opened.value == 0, "still starting up")
        busy.value = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(opened.value == 1)
    }

    // MARK: Model

    @Test("Copy removes only the crashes that are in the report; the ones left out stay")
    func modelRemovesOnlyIncludedCrashes() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        // Each is about 150 KB: three do not fit the 256 KB a report may have, so the oldest are left out.
        for index in 1...3 {
            store.save(
                diagnosticJSON: Scratch.crash(distinct: index, padding: 150_000),
                crashedAt: Date(timeIntervalSinceNow: -3600 + Double(index)), fallback: Scratch.fallback)
        }
        let delivered = Delivered()
        let model = CrashReportModel(
            store: store, preferences: scratch.preferences, environment: Scratch.environment,
            deliver: { text, subject in delivered.record(text, subject) })
        #expect(model.reports.count == 3)
        #expect(model.includedReports.count < 3 && !model.includedReports.isEmpty)
        let includedIDs = Set(model.includedReports.map(\.id))
        let leftOut = model.reports.filter { !includedIDs.contains($0.id) }.map(\.id)

        model.copyAndOpenEmail()
        let remaining = Set(store.pending().map(\.id))
        #expect(remaining == Set(leftOut), "only the crashes that were in the report are deleted")
        #expect(delivered.count == 1)
        #expect(delivered.subject == CrashReportCopy.mailSubject)
        #expect(model.state == .copied)
        #expect(scratch.preferences.offerToSend, "copying does not turn the offer off by itself")
    }

    @Test("Don't Send deletes the listed crashes, and Don't ask again turns the offer off; nothing is copied")
    func modelDontSend() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        store.save(diagnosticJSON: Scratch.crash(distinct: 2), crashedAt: Date(), fallback: Scratch.fallback)
        let delivered = Delivered()
        let model = CrashReportModel(
            store: store, preferences: scratch.preferences, environment: Scratch.environment,
            deliver: { text, subject in delivered.record(text, subject) })
        // A crash that arrives while the window is open waits for the next time.
        store.save(diagnosticJSON: Scratch.crash(distinct: 3), crashedAt: Date(), fallback: Scratch.fallback)
        model.dontAskAgain = true
        model.dontSend()
        #expect(store.pending().count == 1, "the late crash is not the window's to delete")
        #expect(!scratch.preferences.offerToSend)
        #expect(delivered.count == 0)
    }

    @Test("What the crash window previews is, byte for byte, what is copied")
    func crashPreviewIsWhatIsCopied() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        let delivered = Delivered()
        let model = CrashReportModel(
            store: store, preferences: scratch.preferences, environment: Scratch.environment,
            deliver: { text, subject in delivered.record(text, subject) })
        model.note = "  I was in a call  "
        let preview = model.previewText
        #expect(preview.contains("I was in a call"))
        model.copyAndOpenEmail()
        #expect(Data(delivered.text.utf8) == Data(preview.utf8))
        #expect(Data(preview.utf8) == (try model.report.encoded()))
        #expect(preview.utf8.count <= FeedbackLimits.reportBytesMax)
    }

    @Test("A crash note longer than the limit cannot be copied")
    func crashNoteLimit() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = scratch.makeStore()
        store.save(diagnosticJSON: Scratch.crash(distinct: 1), crashedAt: Date(), fallback: Scratch.fallback)
        let model = CrashReportModel(
            store: store, preferences: scratch.preferences, environment: Scratch.environment, deliver: { _, _ in })
        model.note = String(repeating: "a", count: FeedbackLimits.messageMax)
        #expect(model.canCopy)
        model.note += "a"
        #expect(model.noteIsTooLong && !model.canCopy)
    }

    // MARK: Problem report

    @Test("The problem report's limits are FeedbackLimits' and count UTF-16 units")
    func problemMessageLimits() {
        let model = ReportProblemModel(environment: Scratch.environment, loadLogs: { nil }, deliver: { _, _ in })
        model.message = String(repeating: "a", count: FeedbackLimits.messageMin - 1)
        #expect(model.messageIsTooShort && !model.canCopy)
        model.message = String(repeating: "a", count: FeedbackLimits.messageMin)
        #expect(model.canCopy)
        model.message = String(repeating: "a", count: FeedbackLimits.messageMax)
        #expect(model.canCopy && !model.messageIsTooLong)
        model.message = String(repeating: "a", count: FeedbackLimits.messageMax + 1)
        #expect(model.messageIsTooLong && !model.canCopy)
        // An emoji is two UTF-16 units: 2,501 of them are 5,002.
        model.message = String(repeating: "😀", count: FeedbackLimits.messageMax / 2 + 1)
        #expect(model.messageIsTooLong && !model.canCopy)
        #expect(FeedbackLimits.messageMin == 10 && FeedbackLimits.messageMax == 5000)
    }

    @Test("What the problem window previews is, byte for byte, what is copied; the log is off until asked for")
    func problemPreviewIsWhatIsCopied() async {
        let delivered = Delivered()
        let model = ReportProblemModel(
            environment: Scratch.environment, loadLogs: { "2026-10-17T10:00:00Z [app] Started up" },
            deliver: { text, subject in delivered.record(text, subject) })
        model.message = "Listening stops after a minute."
        #expect(!model.includeLogs && model.includeDiagnostics)
        #expect(!model.previewText.contains("Started up"))
        #expect(model.previewText.contains("Mac16,1"))

        model.includeLogs = true
        await model.logsToggled()
        #expect(model.previewText.contains("Started up"))

        model.includeDiagnostics = false
        let preview = model.previewText
        #expect(!preview.contains("Mac16,1") && !preview.contains("arm64"), "diagnostics off: no Mac details")

        model.copyAndOpenEmail()
        #expect(Data(delivered.text.utf8) == Data(preview.utf8))
        #expect(delivered.subject == ReportProblemCopy.mailSubject)
        #expect(preview.utf8.count <= FeedbackLimits.reportBytesMax)
    }

    @Test("The mail link holds the support address and one line, never the report")
    func mailLink() {
        let url = ReportDelivery.mailURL(subject: "Takeheed problem report")
        let text = url.absoluteString
        #expect(text.hasPrefix("mailto:\(ReportDelivery.supportAddress)?"))
        #expect(text.contains("subject=Takeheed%20problem%20report"))
        #expect(text.count < 300)
        var copied: [String] = []
        var order: [String] = []
        ReportDelivery.copyAndOpenMail(
            text: "REPORT", subject: "S", copy: { copied.append($0); order.append("copy") },
            open: { _ in order.append("open") })
        #expect(copied == ["REPORT"] && order == ["copy", "open"], "the report is on the clipboard before the mail opens")
    }

    // MARK: Text report

    @Test("The text report tells what the app has done in counts, with the last failed save")
    func textReportActivity() {
        var dispatch = DispatchStats()
        dispatch.admitted = 4
        dispatch.heldByCooldown = 2
        dispatch.deliveredByChannel = [.webhook: 3]
        dispatch.failedByChannel = [.ntfy: 1]
        let lines = Diagnostics.activityLines(
            Diagnostics.Activity(
                runtime: RuntimeStats(sessionsStarted: 5, deliveriesStarted: 4, transientFailures: 2, fallingBehindReports: 1),
                dispatch: dispatch, configSaveError: "NSCocoaErrorDomain 640", historySaveError: nil))
        let text = lines.joined(separator: "\n")
        #expect(text.contains("Listening sessions started: 5"))
        #expect(text.contains("Hits let through: 4; held back by the wait between alerts: 2"))
        #expect(text.contains("Delivered: Webhook 3"))
        #expect(text.contains("Failed: ntfy push 1"))
        #expect(text.contains("Last failed save of settings: NSCocoaErrorDomain 640"))
        #expect(text.contains("Last failed save of history: none"))
    }

    @Test("The problem report's environment names the Mac and the install, no words")
    func environmentHoldsNoWords() async {
        let controller = DemoFixtures.controller(.off)
        let environment = await Diagnostics.environment(for: controller)
        #expect(environment.appVersion == AppInfo.version && environment.build == AppInfo.build)
        #expect(!environment.macModel.isEmpty && environment.macModel != "unknown")
        #expect(["arm64", "x86_64"].contains(environment.architecture))
        let json = String(decoding: (try? JSONEncoder().encode(environment)) ?? Data(), as: UTF8.self)
        for rule in controller.configuration.rules {
            #expect(!json.contains(rule.name))
            for term in rule.terms { #expect(!json.contains(term)) }
        }
    }
}

// MARK: Log collector and privacy

@Suite("App log collector")
@MainActor
struct AppLogCollectorTests {
    @Test("Debug lines never get in, whatever they say")
    func neverDebug() {
        let debug = DiagnosticLogLine(date: Date(), category: "x", message: "plain", level: .debug)
        #expect(!AppLogCollector.filter.includes(debug))
        for level in [DiagnosticLogLevel.info, .notice, .error, .fault] {
            #expect(AppLogCollector.filter.includes(DiagnosticLogLine(date: Date(), category: "x", message: "plain", level: level)))
        }
        #expect(AppLogCollector.level(of: .debug) == .debug)
        #expect(AppLogCollector.level(of: .undefined) == .debug)
    }

    @Test("Every excluded prefix keeps its line out, and nothing else changes")
    func excludedPrefixes() {
        for prefix in AppLogCollector.excludedMessagePrefixes {
            let line = DiagnosticLogLine(date: Date(), category: "x", message: prefix + " /Users/someone/secret", level: .error)
            #expect(!AppLogCollector.filter.includes(line), "\(prefix)")
        }
    }

    @Test("A line the app logged with a private value is not in the collected log, though the store returns it unredacted")
    func privateValuesStayOut() async {
        let logger = Log.logger("collector-test")
        let marker = String(UUID().uuidString.prefix(8))
        let secret = "SECRET-\(marker)"
        logger.error("Alert delivery failed (ntfy): \(secret, privacy: .private)")
        logger.error("Collector test kept line \(marker, privacy: .public)")
        var lines: [DiagnosticLogLine] = []
        for _ in 0..<40 {
            if case .success(let found) = await AppLogCollector.lines(limit: 500) {
                lines = found.filter { $0.message.contains(marker) }
            }
            if !lines.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(lines.count == 1, "\(lines)")
        #expect(!lines.contains { $0.message.contains("SECRET") })
        #expect(lines.allSatisfy { $0.level != .debug })
    }

    /// The log calls of the app and the package, with the level, the start of the message and the whole call.
    private struct LogCall {
        var file: String
        var level: String
        var head: String
        var text: String
    }

    private static func logCalls() throws -> [LogCall] {
        let root = RenderHarness.repositoryRoot
        var calls: [LogCall] = []
        for folder in ["NameAlert", "Packages/NameAlertKit/Sources"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                calls += SwiftLogScanner.calls(in: source).map {
                    LogCall(file: url.lastPathComponent, level: $0.level, head: $0.head, text: $0.text)
                }
            }
        }
        return calls
    }

    @Test("The scan finds the app's log calls")
    func scanFindsCalls() throws {
        let calls = try Self.logCalls()
        #expect(calls.count > 60, "\(calls.count)")
        #expect(calls.contains { $0.level == "debug" && $0.text.contains("privacy: .private") })
    }

    @Test("Every info-and-above log call that logs a private value starts with an excluded prefix, and no prefix is stale")
    func everyPrivateLogCallIsExcluded() throws {
        let calls = try Self.logCalls()
        let loud = calls.filter { $0.level != "debug" }
        let privateOnes = loud.filter { $0.text.contains("privacy: .private") }
        #expect(!privateOnes.isEmpty)
        for call in privateOnes {
            let covered = AppLogCollector.excludedMessagePrefixes.contains { call.head.hasPrefix($0) }
            #expect(covered, "\(call.file): \"\(call.head)\" logs a private value (OSLogStore returns it unredacted) but is not excluded")
        }
        for prefix in AppLogCollector.excludedMessagePrefixes {
            #expect(loud.contains { $0.head.hasPrefix(prefix) }, "No log call starts with \"\(prefix)\" any more")
        }
    }

    @Test("No info-and-above log call prints heard text, a rule word, an address or a token as public")
    func noPublicSensitiveValues() throws {
        let sensitive = try NSRegularExpression(
            pattern: #"\\\(\s*([A-Za-z0-9_.]*(?:transcript|excerpt|matchedText|heard|token|secret|topic|url|webhook|address|term|context|matched)[A-Za-z0-9_.]*)\s*,\s*privacy:\s*\.public"#,
            options: [.caseInsensitive])
        // A count of them, or a file's name, says nothing that was heard or set up.
        func isHarmless(_ expression: String) -> Bool {
            expression.hasSuffix(".count") || expression.hasSuffix("lastPathComponent") || expression == "context"
        }
        for call in try Self.logCalls() where call.level != "debug" {
            let range = NSRange(call.text.startIndex..., in: call.text)
            for match in sensitive.matches(in: call.text, range: range) {
                guard let found = Range(match.range(at: 1), in: call.text) else { continue }
                let expression = String(call.text[found])
                #expect(
                    isHarmless(expression),
                    "\(call.file): \"\(call.head)\" logs \(expression), which looks sensitive, as public")
            }
        }
    }

    @Test("Debug logging is the only place heard text is logged")
    func heardTextOnlyAtDebug() throws {
        let heard = try NSRegularExpression(
            pattern: #"\\\(\s*(text|update\.text|transcript)\s*,"#)
        for call in try Self.logCalls() where call.level != "debug" {
            let range = NSRange(call.text.startIndex..., in: call.text)
            #expect(heard.firstMatch(in: call.text, range: range) == nil, "\(call.file): \"\(call.head)\"")
        }
    }
}

// MARK: Privacy manifest

@Suite("Privacy manifest")
@MainActor
struct PrivacyManifestTests {
    @Test("Nothing is collected off the device: NSPrivacyCollectedDataTypes is empty, and nothing tracks")
    func collectedTypesEmpty() throws {
        let url = RenderHarness.repositoryRoot.appendingPathComponent("NameAlert/Resources/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let collected = try #require(plist["NSPrivacyCollectedDataTypes"] as? [Any])
        #expect(collected.isEmpty, "crash and problem reports never leave the Mac by themselves")
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    }

    @Test("The reports code never uses the network")
    func noNetworkInReportCode() throws {
        let root = RenderHarness.repositoryRoot
        let forbidden = ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "URLSessionWebSocketTask"]
        for folder in ["NameAlert/Crashes", "NameAlert/Feedback"] {
            let base = root.appendingPathComponent(folder)
            for url in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for word in forbidden {
                    #expect(!source.contains(word), "\(url.lastPathComponent) uses \(word)")
                }
            }
        }
        let mail = try String(contentsOf: root.appendingPathComponent("NameAlert/Support/ReportDelivery.swift"), encoding: .utf8)
        #expect(!mail.contains("URLSession"))
    }
}

// MARK: Helpers

/// A counter a test closure can bump.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// What a report delivery was handed.
@MainActor
private final class Delivered {
    private(set) var count = 0
    private(set) var text = ""
    private(set) var subject = ""
    func record(_ text: String, _ subject: String) {
        count += 1
        self.text = text
        self.subject = subject
    }
}

/// Finds `logger.info(…)`-style calls in Swift source, string-literal aware (a "(" in the message, an interpolation
/// with its own strings).
enum SwiftLogScanner {
    struct Call {
        var level: String
        /// The message up to its first interpolation, whitespace at its start dropped.
        var head: String
        /// The whole call.
        var text: String
    }

    static func calls(in source: String) -> [Call] {
        let characters = Array(source)
        guard let pattern = try? NSRegularExpression(
            pattern: #"[lL]og(?:ger)?\.(info|notice|error|fault|warning|critical|debug)\("#)
        else { return [] }
        var result: [Call] = []
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let levelRange = Range(match.range(at: 1), in: source),
                let wholeRange = Range(match.range, in: source)
            else { continue }
            let start = source.distance(from: source.startIndex, to: wholeRange.upperBound)
            let end = endOfParentheses(in: characters, from: start)
            let text = String(characters[start..<min(end, characters.count)])
            result.append(Call(level: String(source[levelRange]), head: head(of: text), text: text))
        }
        return result
    }

    /// The index just after the `)` that closes a `(` opened before `index`.
    private static func endOfParentheses(in c: [Character], from index: Int) -> Int {
        var depth = 1
        var i = index
        while i < c.count {
            switch c[i] {
            case "\"": i = endOfString(in: c, from: i)
                continue
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return c.count
    }

    /// The index just after the string literal that starts at `index`.
    private static func endOfString(in c: [Character], from index: Int) -> Int {
        let isMultiline = index + 2 < c.count && c[index + 1] == "\"" && c[index + 2] == "\""
        var i = index + (isMultiline ? 3 : 1)
        while i < c.count {
            if c[i] == "\\" {
                if i + 1 < c.count, c[i + 1] == "(" {
                    i = endOfParentheses(in: c, from: i + 2) + 1
                    continue
                }
                i += 2
                continue
            }
            if c[i] == "\"" {
                if !isMultiline { return i + 1 }
                if i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" { return i + 3 }
            }
            i += 1
        }
        return c.count
    }

    private static func head(of text: String) -> String {
        guard let open = text.firstIndex(of: "\"") else { return "" }
        var rest = text[open...]
        rest = rest.hasPrefix("\"\"\"") ? rest.dropFirst(3) : rest.dropFirst(1)
        var head = ""
        var previous: Character = " "
        for character in rest {
            if character == "(" && previous == "\\" { head.removeLast(); break }
            if character == "\"" { break }
            head.append(character)
            previous = character
        }
        return String(head.drop { $0.isWhitespace })
    }
}
