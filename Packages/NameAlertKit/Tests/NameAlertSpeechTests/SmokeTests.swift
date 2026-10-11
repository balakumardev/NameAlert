import NameAlertSpeech
import Testing

@Suite("NameAlertSpeech smoke")
struct SmokeTests {
    @Test func moduleNameAndWhisperLink() {
        #expect(NameAlertSpeechInfo.name == "NameAlertSpeech")
        #expect(!NameAlertSpeechInfo.whisperSystemInfo().isEmpty)
    }
}
