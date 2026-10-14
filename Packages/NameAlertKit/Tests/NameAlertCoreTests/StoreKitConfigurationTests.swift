import Foundation
import NameAlertCore
import Testing

/// `Pro.storekit`, the StoreKit configuration that Debug runs and the StoreKit tests use, must say what App Store
/// Connect says. App Store Connect enforces the length limits; the file does not, so this test does.
@Suite("Pro.storekit")
struct StoreKitConfigurationTests {
    /// This file is Packages/NameAlertKit/Tests/NameAlertCoreTests/StoreKitConfigurationTests.swift.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // NameAlertCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // NameAlertKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()

    private struct File: Decodable {
        struct Product: Decodable {
            struct Localization: Decodable {
                let description: String
                let displayName: String
                let locale: String
            }

            let displayPrice: String
            let familyShareable: Bool
            let productID: String
            let type: String
            let localizations: [Localization]
        }

        struct Settings: Decodable {
            let _developerTeamID: String
        }

        struct Empty: Decodable {}

        let products: [Product]
        let subscriptionGroups: [Empty]
        let nonRenewingSubscriptions: [Empty]
        let settings: Settings
    }

    @Test func sellsOneLifetimeProAtTheAgreedPrice() throws {
        let data = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("Pro.storekit"))
        let file = try JSONDecoder().decode(File.self, from: data)
        #expect(file.subscriptionGroups.isEmpty)
        #expect(file.nonRenewingSubscriptions.isEmpty)
        #expect(file.settings._developerTeamID == "KHD36T7C97")
        #expect(file.products.count == 1)
        let product = try #require(file.products.first)
        #expect(product.productID == ProProduct.id)
        #expect(product.type == "NonConsumable")
        #expect(product.displayPrice == "4.99")
        #expect(!product.familyShareable, "Family Sharing is off: Pro belongs to the Apple Account that buys it")
        let english = try #require(product.localizations.first { $0.locale == "en_US" })
        #expect((2...30).contains(english.displayName.count), "App Store Connect takes 2 to 30 characters")
        #expect(english.description.count <= 45, "App Store Connect takes at most 45 characters")
    }
}
