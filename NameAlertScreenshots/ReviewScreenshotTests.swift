import AppKit
import CoreGraphics
import Foundation
import NameAlertCore
import NameAlertRuntime
import StoreKit
import StoreKitTest
import SwiftUI
import Testing

@testable import ScreenshotHost

/// The App Review screenshot of the Pro purchase. It is written only when `scripts/render_screenshots.sh --review` asks
/// (`NAMEALERT_RENDER_REVIEW_SCREENSHOT=1`): Settings → Pro as a new customer sees it, the product and its price from
/// `Pro.storekit` through StoreKit testing, centred on plain grey, 2880 × 1800, no caption.
@Suite(
    "App Review screenshot", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["NAMEALERT_RENDER_REVIEW_SCREENSHOT"] == "1"))
@MainActor
struct ReviewScreenshotTests {
    @Test("The Pro purchase, for its App Review screenshot")
    func pro() async throws {
        let session = try SKTestSession(contentsOf: RenderHarness.repositoryRoot.appendingPathComponent("Pro.storekit"))
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let suite = "dev.balakumar.namealert.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProStore(isEnforced: true, cache: ProAccessCache(defaults: defaults))
        store.start { _ in }
        defer { store.stop() }
        #expect(await pollUntil(timeout: .seconds(15)) { store.productState == .loaded && store.status == .free })
        let controller = DemoFixtures.controller(.off, configuration: DemoFixtures.settingsConfiguration, proAccess: .free)
        let picture = try await ScreenshotPictures.settings(
            .pro, size: CGSize(width: 760, height: 540), controller: controller, store: store, seed: nil)
        let url = try ScreenshotComposer.writePNG(
            try ReviewScreenshot.compose(picture), name: ProProduct.id, in: ReviewScreenshot.outputDirectory)
        print("[screenshots] wrote \(url.path)")
    }
}

/// How the App Review screenshot is put together.
enum ReviewScreenshot {
    static let canvas = CGSize(width: 2880, height: 1800)

    /// `NAMEALERT_SCREENSHOTS_OUT`, else `appstore/review-screenshots` in the repository.
    @MainActor static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["NAMEALERT_SCREENSHOTS_OUT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return RenderHarness.repositoryRoot.appendingPathComponent("appstore/review-screenshots", isDirectory: true)
    }

    /// The window at the size it was captured (smaller if it would not fit with a margin), centred on plain grey.
    static func compose(_ picture: ScreenshotPicture) throws -> CGImage {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderHarness.RenderError.noBitmap("review screenshot") }
        context.setFillColor(CGColor(srgbRed: 0xD1 / 255, green: 0xD1 / 255, blue: 0xD6 / 255, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        let width = CGFloat(picture.image.width), height = CGFloat(picture.image.height)
        let scale = min(1, (canvas.width - 160) / width, (canvas.height - 160) / height)
        let size = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
        context.interpolationQuality = .high
        context.draw(picture.image, in: CGRect(origin: origin, size: size))
        guard let image = context.makeImage() else { throw RenderHarness.RenderError.noBitmap("review screenshot") }
        return image
    }
}
