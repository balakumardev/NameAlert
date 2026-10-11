import CoreAudio
import Foundation
import NameAlertCore

/// What one look at Core Audio's process list gave.
struct ProcessListReading: Sendable, Equatable {
    /// The processes that could be identified, recording or not.
    var processes: [AudioProcessSnapshot]
    /// How many process objects Core Audio listed. More than `processes.count` when some could not be read.
    var objectCount: Int
    /// The status Core Audio answered with when it would not hand over the list, or `nil` when it did.
    var failure: OSStatus?

    init(processes: [AudioProcessSnapshot], objectCount: Int? = nil, failure: OSStatus? = nil) {
        self.processes = processes
        self.objectCount = objectCount ?? processes.count
        self.failure = failure
    }
}

/// Works out what the call detector tells the log, so that a stream does not say the same thing every second: how
/// many processes there are, once when the stream starts, and why the list could not be read, once for each reason
/// until a read works again. An entry holds counts and a status, never the name or the ID of a process, so that which
/// apps are recording stays out of the log.
struct ProcessListLogbook {
    enum Entry: Equatable {
        case started(processObjects: Int, recordingInput: Int)
        case unreadable(OSStatus)
    }

    private var started = false
    private var reportedFailure: OSStatus?

    /// What to log for the next look at the list, which is nothing most of the time.
    mutating func entries(for reading: ProcessListReading) -> [Entry] {
        var entries: [Entry] = []
        if !started {
            started = true
            entries.append(
                .started(
                    processObjects: reading.objectCount,
                    recordingInput: reading.processes.filter(\.isRunningInput).count))
        }
        if let status = reading.failure {
            if status != reportedFailure {
                reportedFailure = status
                entries.append(.unreadable(status))
            }
        } else {
            reportedFailure = nil
        }
        return entries
    }
}

/// Watches for calls: moments when another app is recording from the microphone.
///
/// "Only during calls" mode uses it to listen while a call is going on and not all day. Core Audio lists the
/// processes connected to it and says which of them are recording. Reading that list needs no permission, so the
/// user is not asked anything, and it works inside the App Sandbox. It exists from macOS 14.2 (`isSupported`).
///
/// What counts as a call is decided by `CallDetectionLogic`. This type looks at the list every `pollInterval` and
/// passes the changes on.
///
/// What it sees is written to the log (category "calls") as counts and statuses only; see `states()`.
public actor CallDetector {
    /// Everything a stream needs, so that it does not have to come back to the actor while it polls.
    private struct Settings: Sendable {
        let pollInterval: Duration
        let ownPID: Int32
        let ownBundleID: String
        let browserDelay: TimeInterval
        let grace: TimeInterval
        let reading: @Sendable () -> ProcessListReading
    }

    private static let log = Log.logger("calls")

    private let settings: Settings

    /// Whether this Mac can list the audio processes: macOS 14.2 or later. The option is hidden before that.
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    /// - Parameter pollInterval: How often the audio processes are looked at.
    public init(pollInterval: Duration = .seconds(1)) {
        self.init(
            pollInterval: pollInterval, ownPID: ProcessInfo.processInfo.processIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier ?? "dev.balakumar.namealert",
            reading: { CallDetector.currentReading() })
    }

    /// For tests: `reading` stands in for Core Audio, and the browser delay and the grace can be set.
    init(
        pollInterval: Duration, ownPID: Int32, ownBundleID: String, browserDelay: TimeInterval = 3,
        grace: TimeInterval = 8, reading: @escaping @Sendable () -> ProcessListReading
    ) {
        settings = Settings(
            pollInterval: pollInterval, ownPID: ownPID, ownBundleID: ownBundleID, browserDelay: browserDelay,
            grace: grace, reading: reading)
    }

    /// The state of the call now, and then every time it changes. The first state is always delivered.
    ///
    /// Each stream looks at the processes on its own, starting from nothing seen, so it needs a few seconds of
    /// looking before it can say a browser has been recording long enough. Polling stops when the stream is cancelled
    /// or no longer read.
    ///
    /// Each stream writes one line to the log when it starts: how many audio processes Core Audio lists and how many
    /// of them are recording. That tells a list that comes back empty from a call that is simply not there. If Core
    /// Audio refuses to hand over the list, the status it answered with is logged as an error, once for each status.
    /// Only counts and statuses are logged, never which apps are recording.
    ///
    /// Not isolated to the actor: it reads nothing but the settings made in `init`, which never change.
    public nonisolated func states() -> AsyncStream<CallState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CallState.self)
        let settings = settings
        let polling = Task.detached(priority: .utility) {
            await Self.poll(settings, into: continuation)
        }
        continuation.onTermination = { _ in polling.cancel() }
        return stream
    }

    private static func poll(_ settings: Settings, into continuation: AsyncStream<CallState>.Continuation) async {
        var logic = CallDetectionLogic(
            ownPID: settings.ownPID, ownBundleID: settings.ownBundleID, browserDelay: settings.browserDelay,
            grace: settings.grace)
        var logbook = ProcessListLogbook()
        var last: CallState?
        while !Task.isCancelled {
            let reading = settings.reading()
            for entry in logbook.entries(for: reading) { write(entry) }
            let state = logic.update(processes: reading.processes, now: Date())
            if state != last {
                last = state
                continuation.yield(state)
            }
            do {
                try await Task.sleep(for: settings.pollInterval)
            } catch {
                break  // cancelled: nobody is listening any more
            }
        }
        continuation.finish()
    }

    private static func write(_ entry: ProcessListLogbook.Entry) {
        switch entry {
        case .started(let processObjects, let recordingInput):
            log.info("""
                Watching for calls: \(processObjects, privacy: .public) audio processes, \
                \(recordingInput, privacy: .public) recording input
                """)
        case .unreadable(let status):
            log.error("""
                Could not read the audio process list (OSStatus \(status, privacy: .public)). \
                Calls cannot be seen while this lasts.
                """)
        }
    }

    /// The processes connected to Core Audio right now, recording or not, as they are listed. Empty before macOS 14.2,
    /// or when Core Audio does not answer.
    public static func currentProcesses() -> [AudioProcessSnapshot] {
        currentReading().processes
    }

    /// `currentProcesses()` with what else Core Audio said: how many process objects there were, and the status of the
    /// call that failed if the list could not be read.
    static func currentReading() -> ProcessListReading {
        if #available(macOS 14.2, *) {
            return CoreAudioProcessList.read()
        }
        return ProcessListReading(processes: [])
    }
}

// MARK: - Core Audio

/// Reads the process objects of Core Audio's system object. Each call to the HAL can fail on its own, for example
/// when a process exits while it is read; then that process, or just that detail of it, is left out.
@available(macOS 14.2, *)
private enum CoreAudioProcessList {
    static func read() -> ProcessListReading {
        let (objects, failure) = processObjects()
        let processes = objects.compactMap { object -> AudioProcessSnapshot? in
            // A process without a process ID cannot be told from another, or from ourselves.
            guard let pid: Int32 = integer(kAudioProcessPropertyPID, of: object), pid > 0 else { return nil }
            let isRunningInput: UInt32 = integer(kAudioProcessPropertyIsRunningInput, of: object) ?? 0
            return AudioProcessSnapshot(pid: pid, bundleID: bundleID(of: object), isRunningInput: isRunningInput != 0)
        }
        return ProcessListReading(processes: processes, objectCount: objects.count, failure: failure)
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// The process objects Core Audio knows. The list can change between asking how long it is and reading it; a
    /// read that no longer fits is simply made again. When Core Audio will not hand the list over, there are no
    /// objects and the status of the call that failed comes with them (the last one, if the read was tried again).
    private static func processObjects() -> (objects: [AudioObjectID], failure: OSStatus?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        let stride = MemoryLayout<AudioObjectID>.stride
        var failure: OSStatus?
        for _ in 0..<3 {
            var size: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
            guard sizeStatus == noErr else { return ([], sizeStatus) }
            guard Int(size) >= stride else { return ([], nil) }  // no process is connected: not a failure
            var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / stride)
            let status = objects.withUnsafeMutableBytes { buffer in
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, buffer.baseAddress!)
            }
            if status == noErr {
                return (Array(objects.prefix(Int(size) / stride)), nil)  // `size` is what was really returned
            }
            failure = status
        }
        return ([], failure)
    }

    /// A number property, such as the process ID (`pid_t`) or a flag (`UInt32`).
    private static func integer<Value: FixedWidthInteger>(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> Value? {
        var address = propertyAddress(selector)
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// The bundle ID of the process, or `nil` when it has none.
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        // Core Audio hands over a CFString that the caller has to release (see AudioHardware.h). It is read as an
        // unmanaged reference and taken over exactly once: released when the Swift string has been made from it.
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &reference) == noErr, let reference
        else { return nil }
        let bundleID = reference.takeRetainedValue() as String
        return bundleID.isEmpty ? nil : bundleID
    }
}
