import Foundation
import NameAlertCore
import NameAlertRuntime
import SwiftUI

/// One line saying what NameAlert is doing: "Listening · System audio", "Paused", "Snoozed until 10:45",
/// "Downloading speech model… 45%", or what went wrong. Its helpers name sources, engines and problems for any other
/// screen that shows them.
struct StatusText: View {
    let state: ListeningState

    var body: some View {
        Text(verbatim: Self.title(for: state))
    }

    static func title(for state: ListeningState, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch state {
        case .off: "Paused"
        case .preparing(let stage): title(for: stage)
        case .listening(let info): "Listening · \(sourceName(info.source))"
        case .waitingForCall: "Waiting for a call"
        case .snoozed(let until): "Snoozed until \(time(of: until, now: now, calendar: calendar))"
        case .error(let issue): title(for: issue)
        }
    }

    static func title(for stage: PreparationStage) -> String {
        switch stage {
        case .permissions, .starting: "Starting…"
        case .downloadingModel(let fraction): "Downloading speech model… \(percent(fraction))"
        case .installingAppleAssets(let fraction): "Preparing Apple speech… \(percent(fraction))"
        }
    }

    /// A short headline for a problem; `message(for:)` says more.
    static func title(for issue: ListeningIssue) -> String {
        switch issue {
        case .permissionDenied(.screenRecording): "Screen Recording is off"
        case .permissionDenied(.microphone): "Microphone access is off"
        case .permissionDenied(.speechRecognition): "Speech Recognition is off"
        case .permissionDenied(.notifications): "Notifications are off"
        case .engineUnavailable: "Speech recognition unavailable"
        case .modelMissing: "Speech model missing"
        case .captureFailed: "Can't capture audio"
        case .engineFailed: "Speech recognition stopped"
        }
    }

    /// What is wrong, in one or two sentences.
    static func message(for issue: ListeningIssue) -> String {
        let app = AppInfo.displayName
        return switch issue {
        case .permissionDenied(.screenRecording): "\(app) needs Screen Recording to hear calls and videos."
        case .permissionDenied(.microphone): "\(app) needs the microphone to hear the people around you."
        case .permissionDenied(.speechRecognition): "\(app) needs Speech Recognition to turn speech into text."
        case .permissionDenied(.notifications): "\(app) needs notifications to show its alerts."
        case .engineUnavailable(let reason): reason
        case .modelMissing: "The local speech model isn't downloaded."
        case .captureFailed(let message), .engineFailed(let message): message
        }
    }

    static func sourceName(_ source: AudioSourceKind) -> String {
        switch source {
        case .systemAudio: "System audio"
        case .microphone: "Microphone"
        case .both: "System audio + mic"
        }
    }

    static func engineName(_ engine: EngineID) -> String {
        switch engine {
        case .appleSpeechTranscriber: "Apple Speech (on-device)"
        case .appleDictationTranscriber: "Apple Dictation (on-device)"
        case .appleSFSpeech: "Apple Speech (on-device, older model)"
        case .whisperLight: "Local model · Light"
        case .whisperBalanced: "Local model · Balanced"
        }
    }

    /// "10:45", "tomorrow 9:00" or "Oct 14, 9:00", in the user's clock style.
    static func time(of date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "45%", in the user's number style.
    static func percent(_ fraction: Double) -> String {
        min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }
}
