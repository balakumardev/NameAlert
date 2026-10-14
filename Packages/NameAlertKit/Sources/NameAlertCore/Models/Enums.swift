/// Where audio is captured from.
public enum AudioSourceKind: String, Codable, Sendable, CaseIterable { case systemAudio, microphone, both }

/// Whether Takeheed listens all the time or only while a call is running.
public enum ListeningMode: String, Codable, Sendable, CaseIterable { case always, duringCalls }

/// Which speech recognizer the user prefers; `automatic` lets the app pick.
public enum EnginePreference: String, Codable, Sendable, CaseIterable { case automatic, apple, localModel }

/// Size of the downloadable on-device model.
public enum LocalModelSize: String, Codable, Sendable, CaseIterable { case light, balanced }

/// How forgiving name matching is.
public enum Sensitivity: String, Codable, Sendable, CaseIterable { case exact, balanced, loose }

/// The ways Takeheed can tell the user about a hit.
public enum ChannelKind: String, Codable, Sendable, CaseIterable {
    case sound, notification, persistentAlarm, screenFlash, ntfy, telegramCall, webhook
}

/// The concrete recognizer that produced a transcript.
public enum EngineID: String, Codable, Sendable, CaseIterable {
    case appleSpeechTranscriber, appleDictationTranscriber, appleSFSpeech, whisperLight, whisperBalanced
}

public enum NtfyPriority: String, Codable, Sendable, CaseIterable { case `default`, high, urgent }

public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case microphone, screenRecording, speechRecognition, notifications
}

public enum PermissionStatus: String, Codable, Sendable { case granted, denied, notDetermined }
