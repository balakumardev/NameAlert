import Foundation
import Testing

@testable import NameAlertCore

@Suite("AppName")
struct AppNameTests {
    @Test func theDisplayNameIsTheName() {
        #expect(AppName.name(displayName: "Name Pro") == "Name Pro")
        #expect(AppName.name(displayName: "  Name Pro \n") == "Name Pro")
    }

    @Test func withoutADisplayNameItIsNameAlert() {
        #expect(AppName.name(displayName: nil) == "NameAlert")
        #expect(AppName.name(displayName: "") == "NameAlert")
        #expect(AppName.name(displayName: " \n") == "NameAlert")
        #expect(AppName.name(displayName: 42) == "NameAlert")
    }

    @Test func currentIsReadFromTheMainBundle() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
        #expect(AppName.current == AppName.name(displayName: displayName))
    }

    @Test func theDefaultTelegramMessageNamesTheApp() {
        #expect(TelegramCallSettings().messageTemplate == "\(AppName.current) heard {keyword}: {context}")
    }
}
