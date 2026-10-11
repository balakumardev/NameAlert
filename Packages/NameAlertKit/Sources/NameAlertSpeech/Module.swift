import whisper

public enum NameAlertSpeechInfo {
    public static let name = "NameAlertSpeech"

    /// whisper.cpp's CPU/GPU feature summary. Calling into the binary target proves it links and loads.
    public static func whisperSystemInfo() -> String {
        String(cString: whisper_print_system_info())
    }
}
