import NameAlertAlerts
import Testing

@Suite("NameAlertAlerts smoke")
struct SmokeTests {
    @Test func moduleName() {
        #expect(NameAlertAlertsInfo.name == "NameAlertAlerts")
    }
}
