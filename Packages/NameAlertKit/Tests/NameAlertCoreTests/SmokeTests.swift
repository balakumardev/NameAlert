import NameAlertCore
import Testing

@Suite("NameAlertCore smoke")
struct SmokeTests {
    @Test func moduleName() {
        #expect(NameAlertCoreInfo.name == "NameAlertCore")
    }
}
