import Foundation
import SwiftUI

/// What audio stream NameAlert listens to.
enum AudioSource: String, CaseIterable, Sendable {
    /// Default. System audio output (Zoom/Teams/YouTube/etc.) via ScreenCaptureKit.
    /// Requires Screen Recording permission.
    case systemAudio
    /// The default microphone input device. Requires Microphone permission.
    case microphone

    var displayName: String {
        switch self {
        case .systemAudio: return "System Audio (Zoom, etc.)"
        case .microphone:  return "Microphone"
        }
    }
}

/// Persistent user settings backed by `@AppStorage` (UserDefaults).
/// Stores keywords as a JSON-encoded `[String]` because `@AppStorage` doesn't
/// support arrays natively.
@MainActor
final class AppSettings: ObservableObject {
    // MARK: Matching
    @AppStorage("keywordsJSON") private var keywordsJSON: String = "[\"bala\"]"
    @AppStorage("fuzzyTolerance") var fuzzyTolerance: Int = 1
    @AppStorage("perKeywordCooldown") var perKeywordCooldown: Double = 8
    @AppStorage("globalCooldown") var globalCooldown: Double = 2

    // MARK: General
    @AppStorage("listenAtLaunch") var listenAtLaunch: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("audioSourceRaw") private var audioSourceRaw: String = AudioSource.systemAudio.rawValue

    var audioSource: AudioSource {
        get { AudioSource(rawValue: audioSourceRaw) ?? .systemAudio }
        set {
            audioSourceRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    // MARK: Beep
    @AppStorage("beepEnabled") var beepEnabled: Bool = true
    @AppStorage("beepSoundName") var beepSoundName: String = "Glass"

    // MARK: Notification
    @AppStorage("notificationEnabled") var notificationEnabled: Bool = true

    // MARK: Persistent (loops sound + modal dialog until dismissed)
    @AppStorage("persistentEnabled") var persistentEnabled: Bool = false
    @AppStorage("persistentSoundName") var persistentSoundName: String = "Sosumi"

    // MARK: ntfy
    @AppStorage("ntfyEnabled") var ntfyEnabled: Bool = false
    @AppStorage("ntfyServer") var ntfyServer: String = "https://ntfy.sh"
    @AppStorage("ntfyTopic") var ntfyTopic: String = ""
    @AppStorage("ntfyAuthToken") var ntfyAuthToken: String = ""

    // MARK: CallMeBot
    @AppStorage("callMeBotEnabled") var callMeBotEnabled: Bool = false
    @AppStorage("callMeBotUser") var callMeBotUser: String = ""
    @AppStorage("callMeBotMessage") var callMeBotMessage: String =
        "NameAlert heard your name: {text}"
    @AppStorage("callMeBotLanguage") var callMeBotLanguage: String = "en-US-Standard-B"

    /// Decoded keyword list. Setter re-encodes back to JSON.
    var keywords: [String] {
        get {
            (try? JSONDecoder().decode([String].self,
                                       from: Data(keywordsJSON.utf8))) ?? []
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            keywordsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
            objectWillChange.send()
        }
    }

    /// Builds the list of currently enabled `Alert`s from settings.
    func enabledAlerts() -> [Alert] {
        var alerts: [Alert] = []
        if beepEnabled {
            alerts.append(BeepAlert(soundName: beepSoundName))
        }
        if notificationEnabled {
            alerts.append(NotificationAlert())
        }
        if persistentEnabled {
            alerts.append(PersistentAlert(soundName: persistentSoundName))
        }
        if ntfyEnabled, !ntfyTopic.isEmpty {
            alerts.append(NtfyAlert(server: ntfyServer,
                                    topic: ntfyTopic,
                                    authToken: ntfyAuthToken.isEmpty ? nil : ntfyAuthToken))
        }
        if callMeBotEnabled, !callMeBotUser.isEmpty {
            alerts.append(CallMeBotAlert(user: callMeBotUser,
                                         messageTemplate: callMeBotMessage,
                                         language: callMeBotLanguage))
        }
        return alerts
    }
}
