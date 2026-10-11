import NameAlertRuntime
import Testing

@Suite("NameAlertRuntime smoke")
struct SmokeTests {
    @Test func moduleName() {
        #expect(NameAlertRuntimeInfo.name == "NameAlertRuntime")
    }
}
