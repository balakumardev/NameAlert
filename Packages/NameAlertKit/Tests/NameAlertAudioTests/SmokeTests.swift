import NameAlertAudio
import Testing

@Suite("NameAlertAudio smoke")
struct SmokeTests {
    @Test func moduleName() {
        #expect(NameAlertAudioInfo.name == "NameAlertAudio")
    }
}
