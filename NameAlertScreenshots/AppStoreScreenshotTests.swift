import AppKit
import CoreGraphics
import Foundation
import ImageIO
import NameAlertAlerts
import NameAlertCore
import NameAlertRuntime
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import ScreenshotHost

// MARK: - What to render, and where it goes

/// The store screenshots are written only when asked for: `scripts/render_screenshots.sh` sets the variables below
/// (through `TEST_RUNNER_…`). An ordinary run of the Screenshots scheme leaves `appstore/screenshots/` alone.
enum ScreenshotEnvironment {
    /// `NAMEALERT_RENDER_SCREENSHOTS=1`.
    static let isRequested = ProcessInfo.processInfo.environment["NAMEALERT_RENDER_SCREENSHOTS"] == "1"

    /// `NAMEALERT_SCREENSHOTS_OUT`, else `appstore/screenshots` in the repository.
    @MainActor static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["NAMEALERT_SCREENSHOTS_OUT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return RenderHarness.repositoryRoot.appendingPathComponent("appstore/screenshots", isDirectory: true)
    }

    /// `NAMEALERT_SCREENSHOTS_ONLY`: comma-separated file-name prefixes ("01,05"); every screenshot when it is empty.
    static func includes(_ spec: ScreenshotSpec) -> Bool {
        let only = (ProcessInfo.processInfo.environment["NAMEALERT_SCREENSHOTS_ONLY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return only.isEmpty || only.contains { spec.name.hasPrefix($0) }
    }
}

/// One screenshot: its file name and the line of text above the picture.
struct ScreenshotSpec: Sendable {
    let name: String
    let headline: String

    static let menuBar = ScreenshotSpec(name: "01-menu-bar", headline: "Know the moment someone says your name")
    static let rules = ScreenshotSpec(name: "02-rules", headline: "Choose what to listen for and how to be alerted")
    static let alerts = ScreenshotSpec(name: "03-alerts", headline: "Sound, notification, alarm, push, call or webhook")
    static let onboarding = ScreenshotSpec(name: "04-onboarding", headline: "Set up in a minute")
    static let live = ScreenshotSpec(name: "05-live", headline: "Your audio never leaves your Mac")

    static let all: [ScreenshotSpec] = [menuBar, rules, alerts, onboarding, live]
}

// MARK: - The five screenshots

/// Renders the five Mac App Store screenshots (2880 × 1800, RGB, no alpha) from the app's real views on demo data and
/// writes them to `appstore/screenshots/`. Run it with `scripts/render_screenshots.sh`.
@Suite("App Store screenshots", .serialized, .enabled(if: ScreenshotEnvironment.isRequested))
@MainActor
struct AppStoreScreenshotTests {
    @Test("01 The menu bar popover, listening, with mentions")
    func menuBar() async throws {
        try await produce(.menuBar) { try await ScreenshotPictures.popover() }
    }

    @Test("02 The Rules editor")
    func rules() async throws {
        try await produce(.rules) { try await ScreenshotPictures.rules() }
    }

    @Test("03 The Alerts settings")
    func alerts() async throws {
        try await produce(.alerts) { try await ScreenshotPictures.alerts() }
    }

    @Test("04 Setup: your name")
    func onboarding() async throws {
        try await produce(.onboarding) { try await ScreenshotPictures.onboarding() }
    }

    @Test("05 The live transcript")
    func live() async throws {
        try await produce(.live) { try await ScreenshotPictures.liveTranscript() }
    }

    private func produce(_ spec: ScreenshotSpec, picture: () async throws -> ScreenshotPicture) async throws {
        guard ScreenshotEnvironment.includes(spec) else { return }
        let image = try ScreenshotComposer.compose(headline: spec.headline, picture: try await picture())
        let url = try ScreenshotComposer.writePNG(image, name: spec.name, in: ScreenshotEnvironment.outputDirectory)
        print("[screenshots] wrote \(url.path)")
    }
}

// MARK: - The pictures of the app

/// What the app drew for one screenshot: the pixels, how big that is in points, and how it is shown on the canvas.
struct ScreenshotPicture {
    /// sRGB pixels, `image.width / size.width` of them to the point.
    let image: CGImage
    /// In points.
    let size: CGSize
    /// Of the window or popover, in points.
    let cornerRadius: CGFloat
    /// The most the picture is enlarged on the canvas, in canvas pixels to the point.
    let maxScale: CGFloat
}

/// Each view as the app draws it, on demo data and the inert stand-ins (nothing listens, downloads or sends), light
/// appearance.
///
/// What an offscreen window cannot do is look like the key window of the active app: AppKit's own switches and
/// segmented controls come out in their gray, inactive colors (the SwiftUI ones, checkboxes and prominent buttons, are
/// told otherwise through `controlActiveState`), and the selected row of a sidebar comes out black (repaired below).
@MainActor
enum ScreenshotPictures {
    /// The popover as it opens while listening, with the mentions of this morning.
    static func popover() async throws -> ScreenshotPicture {
        let controller = DemoFixtures.controller(
            .listening(DemoFixtures.listeningInfo), hits: popoverHits,
            transcript: "okay so before we wrap up I think we should ask Bala to walk us through the numbers", level: 0.62)
        let popover = MenuBarPopover()
            .environment(controller)
            .environment(WindowRouter())
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
        let size = RenderHarness.fittingSize(of: popover, width: nil)
        let image = try await RenderHarness.image(popover, size: size, scale: 5, afterWaiting: .milliseconds(300))
        return ScreenshotPicture(image: image, size: size, cornerRadius: 14, maxScale: 4.4)
    }

    /// Short contexts, so that no row is cut off in the middle of a word.
    private static var popoverHits: [Hit] {
        [
            DemoFixtures.hit(DemoFixtures.nameRule, "Bala", "can Bala share the deck", at: DemoFixtures.today(10, 32)),
            DemoFixtures.hit(DemoFixtures.standupRule, "standup", "standup moves to ten", at: DemoFixtures.today(9, 58)),
            DemoFixtures.hit(DemoFixtures.nameRule, "Bala", "thanks Bala, great point", at: DemoFixtures.today(9, 15)),
        ]
    }

    /// Settings → Rules: ten rules, the first open, a sentence tried, and every way to be alerted ready to choose.
    static func rules() async throws -> ScreenshotPicture {
        var configuration = DemoFixtures.settingsConfiguration
        configuration.rules = [
            Rule(
                name: "My name", terms: ["Bala", "Balakumar", "Bala Kumar"], sensitivity: .balanced,
                channels: [.sound, .notification, .ntfy, .telegramCall], cooldownSeconds: 10),
            Rule(
                name: "Standup", terms: ["standup", "stand-up"], sensitivity: .exact, channels: [.sound, .persistentAlarm],
                cooldownSeconds: 45),
            Rule(name: "Project Atlas", terms: ["Atlas"], channels: [.notification], cooldownSeconds: 120),
            Rule(name: "Acme", terms: ["Acme", "Acme Corp"], channels: [.sound, .notification]),
            Rule(name: "Deadline", terms: ["deadline", "due date"], channels: [.notification, .screenFlash]),
            Rule(name: "Design review", terms: ["design review"], channels: [.notification], cooldownSeconds: 60),
            Rule(name: "Retro", terms: ["retro", "retrospective"], channels: [.notification]),
            Rule(name: "Budget", terms: ["budget"], channels: [.sound, .notification]),
            Rule(name: "Launch", terms: ["launch", "launch day"], channels: [.notification, .ntfy]),
            Rule(name: "Lunch", terms: ["lunch"], channels: [.notification], isEnabled: false),
        ]
        configureAlertChannels(&configuration)
        let controller = DemoFixtures.controller(.off, configuration: configuration)
        return try await settings(
            .rules, size: CGSize(width: 900, height: 750), controller: controller,
            seed: "okay so before we wrap up, can Bala share the screen")
    }

    /// Settings → Alerts: a Mac that allows notifications, with ntfy, Telegram and a webhook set up and nothing failing.
    static func alerts() async throws -> ScreenshotPicture {
        var configuration = DemoFixtures.settingsConfiguration
        configureAlertChannels(&configuration)
        let controller = await SettingsFixtures.controller(configuration: configuration, notifications: .granted)
        // The Settings window is never less than 540 points tall. The picture ends at 522, below the note under Alarm and
        // above the Screen flash heading, so no row is cut in half: Sound, Notification and Alarm, the first three of the
        // headline, as large as the canvas allows.
        return try await settings(
            .alerts, size: CGSize(width: 900, height: 540), visibleHeight: 522, controller: controller, seed: nil)
    }

    private static func configureAlertChannels(_ configuration: inout AppConfiguration) {
        configuration.channels.ntfy.topic = "bala-alerts-7f3k"
        configuration.channels.telegramCall.user = "@bala"
        configuration.channels.webhook.url = "https://hooks.example.com/takeheed"
    }

    /// The Settings window with `section` open, `size` points of it, or only the top `visibleHeight` points when that is
    /// given. The offscreen renderer draws the selected sidebar row as a black rectangle, so that row is painted over
    /// with the row as it looks unselected, under a tint of the accent color.
    private static func settings(
        _ section: SettingsSection, size: CGSize, visibleHeight: CGFloat? = nil, controller: ListeningController,
        seed: String?
    ) async throws -> ScreenshotPicture {
        let scale: CGFloat = 3
        // Nothing here reads the real Keychain, and no secret is shown as saved.
        let secrets = SecretsModel(store: InMemorySecretStore())
        /// The window with `section` open, and where its switches that are on are, in points from its top left.
        func render(_ section: SettingsSection) async throws -> (image: CGImage, switches: [CGRect]) {
            let view = SettingsView(section: section)
                .environment(controller)
                .environment(secrets)
                .environment(WindowRouter())
                .environment(\.matchTesterSeed, seed ?? "")
                .environment(\.controlActiveState, .key)
                .background(Color(nsColor: .windowBackgroundColor))
            var switches: [CGRect] = []
            let image = try await RenderHarness.image(view, size: size, scale: scale, afterWaiting: .milliseconds(500)) { window in
                if let root = window.contentView { switches = ActiveSwitchLook.onSwitchFrames(in: root) }
            }
            return (image, switches)
        }
        let rendered = try await render(section)
        // A render with the row farthest away selected shows this row unselected, and its own black row far from this one.
        let panes = SettingsSection.allCases
        let farthest = (panes.firstIndex(of: section) ?? 0) < panes.count / 2 ? panes[panes.count - 1] : panes[0]
        let other = try await render(farthest).image
        let accent = ScreenshotComposer.accentColor
        let repaired = SidebarSelectionRepair.repaired(
            rendered.image, using: other, searchWidth: Int(190 * scale), margin: Int(2 * scale), tint: accent)
        var picture = repaired ?? rendered.image
        picture = ActiveSwitchLook.recolored(picture, frames: rendered.switches, scale: scale, accent: accent) ?? picture
        var shown = size
        if let visibleHeight, let cropped = picture.cropping(to: CGRect(x: 0, y: 0, width: picture.width, height: Int(visibleHeight * scale))) {
            picture = cropped
            shown.height = visibleHeight
        }
        return ScreenshotPicture(image: picture, size: shown, cornerRadius: 12, maxScale: 2.7)
    }

    /// Setup, on the step where the name is typed.
    static func onboarding() async throws -> ScreenshotPicture {
        var fresh = AppConfiguration()
        fresh.hasCompletedOnboarding = false
        let model = OnboardingModel(configuration: fresh, step: .name)
        model.name = "Bala"
        model.variants = ["Balakumar", "Bala Kumar"]
        let controller = DemoFixtures.controller(.off, configuration: fresh)
        let view = OnboardingView(presetModel: model)
            .environment(controller)
            .environment(WindowRouter())
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
        // The name field takes the keyboard when the step appears, which selects its text; take it away again.
        let image = try await RenderHarness.image(
            view, size: OnboardingView.size, scale: 3, afterWaiting: .milliseconds(500)
        ) { window in
            window.makeFirstResponder(nil)
        }
        return ScreenshotPicture(image: image, size: OnboardingView.size, cornerRadius: 12, maxScale: 2.8)
    }

    /// A stretch of a meeting that fills the live transcript window, with "Bala" and "standup" among the words.
    private static let liveTranscriptText =
        "okay so that covers the roadmap for the quarter. Before we wrap up I want to hear from the design team first. "
        + "Priya, you had a question about the new onboarding flow? Yes, I wanted to check whether we are still planning "
        + "to ship it before the end of the month, because the copy is not final. We are, but the copy can slip a few "
        + "days. Okay, good. Then let's talk about the standup, it moves to ten thirty tomorrow because of the offsite. "
        + "Great. One more thing, can Bala share the screen with the latest numbers? Sure, give me a second to pull "
        + "them up. While he does that, a quick reminder that the standup notes are in the shared doc. Thanks Bala, "
        + "that really helps. Next up is the design review for the settings screens, and after that we can open it up "
        + "for questions about the launch plan. I'll send a recap after the call, and the final numbers will go into "
        + "the shared doc before the end of the day. Nice. For the customer call on Thursday we only need a short demo "
        + "and the pricing sheet, so let's keep the deck under ten slides. I'll also check the wording on the privacy "
        + "page with legal before we publish anything. Last thing, please add your notes to the shared doc by Friday "
        + "so we can plan the next sprint. Thanks, everyone."

    /// What the controller keeps of `liveTranscriptText`: its last words, from the start of a word, at most 300
    /// characters. The window has to be the end of the text the view starts from, or the view cannot tell where the
    /// window belongs and joins the two wrongly.
    private static var liveTranscriptWindow: String {
        let tail = String(liveTranscriptText.suffix(300))
        guard let space = tail.firstIndex(of: " ") else { return tail }
        return String(tail[tail.index(after: space)...])
    }

    /// The live transcript, with the mentions marked and the last mention under it.
    static func liveTranscript() async throws -> ScreenshotPicture {
        let controller = DemoFixtures.controller(
            .listening(DemoFixtures.listeningInfo), hits: DemoFixtures.historyHits, transcript: liveTranscriptWindow,
            level: 0.45)
        let size = CGSize(width: 620, height: 460)
        let view = LiveTranscriptWindow(initialText: liveTranscriptText)
            .environment(controller)
            .environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
        let image = try await RenderHarness.image(view, size: size, scale: 3, afterWaiting: .milliseconds(500))
        return ScreenshotPicture(image: image, size: size, cornerRadius: 12, maxScale: 2.8)
    }
}

// MARK: - The offscreen renderer's black sidebar row

/// The offscreen renderer cannot draw the selected row of a sidebar (it is a material): it comes out as a solid black
/// rectangle with the row's name lost in it. This finds that rectangle and replaces it with the same row from a render
/// in which another row is selected, under a light tint of the accent color, as a selected row looks.
enum SidebarSelectionRepair {
    struct Pill: Equatable {
        var x: Int, y: Int, width: Int, height: Int
    }

    /// RGBA pixels, row 0 at the top.
    struct Pixels {
        let width: Int
        let height: Int
        var data: [UInt8]

        init(_ image: CGImage) {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.width = width
            self.height = height
            self.data = bytes
        }

        func isNearBlack(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return data[offset] <= 12 && data[offset + 1] <= 12 && data[offset + 2] <= 12 && data[offset + 3] == 255
        }

        var cgImage: CGImage? {
            guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// The black rectangle in the first `searchWidth` columns of `pixels`, if there is one: the rows that hold a run of
    /// black at least `minimumRun` pixels long, as a bounding box. The row is a long, solid run; the strokes of the
    /// sidebar's icons are black too, but short.
    static func blackPill(in pixels: Pixels, searchWidth: Int, minimumRun: Int = 100) -> Pill? {
        let limit = min(searchWidth, pixels.width)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<pixels.height {
            var run = 0
            // One column past the end closes a run that reaches it.
            for x in 0...limit {
                if x < limit && pixels.isNearBlack(x, y) {
                    run += 1
                    continue
                }
                if run >= minimumRun {
                    minX = min(minX, x - run)
                    maxX = max(maxX, x - 1)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
                run = 0
            }
        }
        guard maxX >= 0, maxY - minY >= 20 else { return nil }
        return Pill(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// `image` with its black row replaced by the same place in `other`, tinted; `nil` when there is no black row.
    static func repaired(
        _ image: CGImage, using other: CGImage, searchWidth: Int, margin: Int = 4, tint: CGColor
    ) -> CGImage? {
        var base = Pixels(image)
        let replacement = Pixels(other)
        guard base.width == replacement.width, base.height == replacement.height,
            let pill = blackPill(in: base, searchWidth: searchWidth)
        else { return nil }

        // A little beyond the rectangle, for the soft edge of its corners.
        let x0 = max(0, pill.x - margin), x1 = min(base.width, pill.x + pill.width + margin)
        let y0 = max(0, pill.y - margin), y1 = min(base.height, pill.y + pill.height + margin)
        for y in y0..<y1 {
            let start = (y * base.width + x0) * 4, end = (y * base.width + x1) * 4
            base.data.replaceSubrange(start..<end, with: replacement.data[start..<end])
        }
        guard let restored = base.cgImage,
            let context = CGContext(
                data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(restored, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // The context has its origin at the bottom left.
        let rect = CGRect(x: pill.x, y: base.height - pill.y - pill.height, width: pill.width, height: pill.height)
        let radius = rect.height * 0.22
        context.setFillColor(tint.copy(alpha: 0.13) ?? tint)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return context.makeImage()
    }
}

// MARK: - Switches that are on

/// SwiftUI draws a switch with the window it is in, and the offscreen window is not the key window of the active app,
/// so a switch that is on comes out with a gray track where the app shows the accent color. This paints the track of
/// each switch that is on in the accent color: the pixels darker than the background around the switch, in the
/// capsule the track makes, become the accent over that background by as much as they are dark. The knob, which is
/// lighter than the track, is left alone.
enum ActiveSwitchLook {
    /// The frames of the switches under `root` that are on, in points from the top left of `root`.
    @MainActor
    static func onSwitchFrames(in root: NSView) -> [CGRect] {
        var frames: [CGRect] = []
        func visit(_ view: NSView) {
            if let toggle = view as? NSSwitch, toggle.state == .on {
                var frame = toggle.convert(toggle.bounds, to: root)
                if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
                frames.append(frame)
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return frames
    }

    private static func luma(_ data: [UInt8], _ offset: Int) -> Double {
        0.299 * Double(data[offset]) + 0.587 * Double(data[offset + 1]) + 0.114 * Double(data[offset + 2])
    }

    /// `image` with the track of the switches at `frames` (points, `scale` pixels to the point) in `accent`; `nil` when
    /// there is no switch to paint.
    static func recolored(_ image: CGImage, frames: [CGRect], scale: CGFloat, accent: CGColor) -> CGImage? {
        guard !frames.isEmpty, let components = accent.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
            components.count >= 3
        else { return nil }
        let target = (r: components[0] * 255, g: components[1] * 255, b: components[2] * 255)
        var pixels = SidebarSelectionRepair.Pixels(image)
        var painted = false

        for frame in frames {
            let x0 = max(0, Int((frame.minX * scale).rounded(.down))), x1 = min(pixels.width, Int((frame.maxX * scale).rounded(.up)))
            let y0 = max(0, Int((frame.minY * scale).rounded(.down))), y1 = min(pixels.height, Int((frame.maxY * scale).rounded(.up)))
            guard x1 - x0 > 8, y1 - y0 > 8 else { continue }

            // The background around the switch is what its corner shows.
            let corner = (y0 * pixels.width + x0) * 4
            let background = luma(pixels.data, corner)
            let backgroundColor = (r: Double(pixels.data[corner]), g: Double(pixels.data[corner + 1]), b: Double(pixels.data[corner + 2]))

            // The track: what is clearly darker than the background. Its box gives the capsule, and the middle of its
            // values, the track's own color.
            var darker: [Double] = []
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let value = luma(pixels.data, (y * pixels.width + x) * 4)
                    guard value < background - 12 else { continue }
                    darker.append(value)
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard darker.count > 40, maxX > minX, maxY > minY else { continue }
            darker.sort()
            let track = darker[darker.count / 2]
            guard background - track > 8 else { continue }

            // The capsule of the track, a pixel wider than it is: anything beyond it (a shadow) is left as it is.
            let radius = Double(maxY - minY + 1) / 2 + 1
            let left = Double(minX) + radius - 1, right = Double(maxX + 1) - radius + 1, middle = Double(minY + maxY + 1) / 2
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let offset = (y * pixels.width + x) * 4
                    let value = luma(pixels.data, offset)
                    guard value < background - 1 else { continue }
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let nearest = min(max(px, left), right)
                    guard ((px - nearest) * (px - nearest) + (py - middle) * (py - middle)).squareRoot() <= radius else { continue }
                    let weight = min(1, (background - value) / (background - track))
                    pixels.data[offset] = UInt8(max(0, min(255, backgroundColor.r * (1 - weight) + target.r * weight)))
                    pixels.data[offset + 1] = UInt8(max(0, min(255, backgroundColor.g * (1 - weight) + target.g * weight)))
                    pixels.data[offset + 2] = UInt8(max(0, min(255, backgroundColor.b * (1 - weight) + target.b * weight)))
                    painted = true
                }
            }
        }
        return painted ? pixels.cgImage : nil
    }
}

// MARK: - The canvas

enum ScreenshotError: Error, CustomStringConvertible {
    case headlineTooWide(String)

    var description: String {
        switch self {
        case .headlineTooWide(let text): "The headline does not fit on one line: \(text)"
        }
    }
}

/// Puts a picture of the app on the store's canvas: the brand gradient, one line of text, and the picture with a soft
/// shadow.
enum ScreenshotComposer {
    static let canvas = CGSize(width: 2880, height: 1800)

    /// The icon's colors, indigo to violet.
    static let gradientStart = CGColor(srgbRed: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255, alpha: 1)
    static let gradientEnd = CGColor(srgbRed: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255, alpha: 1)

    static let headlineFontSize: CGFloat = 110
    /// The widest the headline may be: one line, with room at the sides.
    static let headlineMaxWidth: CGFloat = 2400
    /// Where the baseline of the headline is, from the top of the canvas.
    static let headlineBaseline: CGFloat = 232
    /// Where the picture sits, from the top left of the canvas.
    static let pictureRegion = CGRect(x: 240, y: 380, width: 2400, height: 1320)

    static var headlineFont: NSFont { .systemFont(ofSize: headlineFontSize, weight: .semibold) }

    /// The app's accent color as the light appearance has it, as sRGB. The asset has a lighter variant for the dark
    /// appearance, which is not what a light window shows (and what this process asks for, on a Mac set to dark).
    static var accentColor: CGColor {
        var color = CGColor(srgbRed: 0.43, green: 0.16, blue: 0.85, alpha: 1)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            if let accent = NSColor(named: "AccentColor", bundle: .main)?.usingColorSpace(.sRGB) {
                color = CGColor(srgbRed: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent, alpha: 1)
            }
        }
        return color
    }

    // MARK: Text

    /// How wide `text` is as the headline, in pixels.
    static func headlineWidth(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: headlineFont]).size().width
    }

    // MARK: Layout

    /// Where the picture goes: as large as the region allows, up to the picture's own limit, centered in it. From the
    /// top left of the canvas.
    static func pictureFrame(for picture: ScreenshotPicture) -> (rect: CGRect, scale: CGFloat) {
        let scale = min(
            pictureRegion.width / picture.size.width, pictureRegion.height / picture.size.height, picture.maxScale)
        let size = CGSize(width: (picture.size.width * scale).rounded(), height: (picture.size.height * scale).rounded())
        let rect = CGRect(
            x: (pictureRegion.midX - size.width / 2).rounded(), y: (pictureRegion.midY - size.height / 2).rounded(),
            width: size.width, height: size.height)
        return (rect, scale)
    }

    // MARK: Drawing

    static func compose(headline: String, picture: ScreenshotPicture) throws -> CGImage {
        let width = Int(canvas.width), height = Int(canvas.height)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard headlineWidth(headline) <= headlineMaxWidth else { throw ScreenshotError.headlineTooWide(headline) }
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderHarness.RenderError.noBitmap("canvas") }
        context.interpolationQuality = .high

        let frame = pictureFrame(for: picture)
        drawBackground(in: context, glowAround: frame.rect)
        drawHeadline(headline, in: context)
        drawPicture(picture, in: frame.rect, scale: frame.scale, context: context)

        guard let image = context.makeImage() else { throw RenderHarness.RenderError.noBitmap("canvas") }
        return image
    }

    /// `rect` from the top left of the canvas, as the drawing context (origin at the bottom left) wants it.
    private static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func drawBackground(in context: CGContext, glowAround rect: CGRect) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let gradient = CGGradient(colorsSpace: srgb, colors: [gradientStart, gradientEnd] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }
        // A soft light behind the picture lifts it off the gradient.
        let glow = [CGColor(gray: 1, alpha: 0.17), CGColor(gray: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: srgb, colors: glow, locations: [0, 1]) {
            let center = CGPoint(x: flipped(rect).midX, y: flipped(rect).midY)
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 1500, options: [])
        }
    }

    private static func drawHeadline(_ headline: String, in context: CGContext) {
        let font = headlineFont
        let text = NSAttributedString(string: headline, attributes: [.font: font, .foregroundColor: NSColor.white])
        let origin = CGPoint(
            x: ((canvas.width - text.size().width) / 2).rounded(),
            // `draw(at:)` puts the bottom of the line box at the point; the baseline is `descender` above it.
            y: canvas.height - headlineBaseline + font.descender)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: origin)
    }

    private static func drawPicture(_ picture: ScreenshotPicture, in rect: CGRect, scale: CGFloat, context: CGContext) {
        let target = flipped(rect)
        let radius = picture.cornerRadius * scale
        let path = CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Two shadows: a wide soft one and a tight one at the edge.
        for (offset, blur, alpha) in [(36.0, 120.0, 0.42), (6.0, 20.0, 0.28)] {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -offset), blur: blur,
                color: CGColor(srgbRed: 0.09, green: 0.04, blue: 0.30, alpha: alpha))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(picture.image, in: target)
        context.restoreGState()

        // A hairline along the edge, as a window has.
        context.saveGState()
        context.addPath(CGPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.30))
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Output

    /// `image` as an RGB PNG without an alpha channel, `<name>.png` in `directory`.
    @discardableResult
    static func writePNG(_ image: CGImage, name: String, in directory: URL) throws -> URL {
        let width = image.width, height = image.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // Draw into a buffer with the alpha byte skipped, then keep only the three color bytes of each pixel.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RenderHarness.RenderError.noBitmap(name) }
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { out in
            for pixel in 0..<(width * height) {
                out[pixel * 3] = rgba[pixel * 4]
                out[pixel * 3 + 1] = rgba[pixel * 4 + 1]
                out[pixel * 3 + 2] = rgba[pixel * 4 + 2]
            }
        }
        guard let provider = CGDataProvider(data: rgb as CFData),
            let opaque = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: srgb,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderHarness.RenderError.noPNG(name) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderHarness.RenderError.noPNG(name) }
        CGImageDestinationAddImage(destination, opaque, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderHarness.RenderError.noPNG(name) }
        return url
    }
}

// MARK: - Logic

/// The canvas, the layout and the sidebar repair, on synthetic pictures: they run with every run of the Screenshots
/// scheme and write nothing into the repository.
@Suite("App Store screenshot logic")
@MainActor
struct AppStoreScreenshotLogicTests {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An image of `width` × `height` pixels in one color, drawn on by `draw` (which gets a context with the origin at
    /// the bottom left) and by the `fill` helper below, which takes the top left as the origin.
    private func image(
        _ width: Int, _ height: Int, background: (UInt8, UInt8, UInt8), draw: (CGContext) -> Void = { _ in }
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    private func color(_ rgb: (UInt8, UInt8, UInt8)) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    /// Fills a rectangle given from the top left of an image `height` pixels tall.
    private func fill(
        _ context: CGContext, _ x: Int, _ y: Int, _ width: Int, _ height: Int, in imageHeight: Int, _ rgb: (UInt8, UInt8, UInt8),
        radius: CGFloat = 0
    ) {
        let rect = CGRect(x: x, y: imageHeight - y - height, width: width, height: height)
        context.setFillColor(color(rgb))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    @Test("The five screenshots have the file names and headlines of the store listing")
    func specs() {
        #expect(ScreenshotSpec.all.map(\.name) == ["01-menu-bar", "02-rules", "03-alerts", "04-onboarding", "05-live"])
        #expect(
            ScreenshotSpec.all.map(\.headline) == [
                "Know the moment someone says your name",
                "Choose what to listen for and how to be alerted",
                "Sound, notification, alarm, push, call or webhook",
                "Set up in a minute",
                "Your audio never leaves your Mac",
            ])
    }

    @Test("Every headline fits on one line, with room at the sides")
    func headlinesFit() {
        for spec in ScreenshotSpec.all {
            let width = ScreenshotComposer.headlineWidth(spec.headline)
            #expect(width <= ScreenshotComposer.headlineMaxWidth, "“\(spec.headline)” is \(Int(width)) pixels wide")
        }
    }

    @Test("A headline that is too wide is refused, not run off the canvas")
    func tooWide() {
        let picture = ScreenshotPicture(
            image: image(10, 10, background: (255, 255, 255)), size: CGSize(width: 10, height: 10), cornerRadius: 0, maxScale: 1)
        #expect(throws: ScreenshotError.self) {
            _ = try ScreenshotComposer.compose(headline: String(repeating: "Much too wide ", count: 12), picture: picture)
        }
    }

    @Test("A picture is as large as the region allows, centered in it, and no larger than its own limit")
    func pictureFrames() {
        let region = ScreenshotComposer.pictureRegion
        let blank = image(10, 10, background: (255, 255, 255))
        for (size, limit) in [
            (CGSize(width: 900, height: 640), CGFloat(2.1)), (CGSize(width: 340, height: 264), 4.4),
            (CGSize(width: 600, height: 460), 2.8), (CGSize(width: 2000, height: 100), 5),
        ] {
            let frame = ScreenshotComposer.pictureFrame(for: ScreenshotPicture(image: blank, size: size, cornerRadius: 12, maxScale: limit))
            #expect(frame.scale <= limit)
            #expect(region.insetBy(dx: -1, dy: -1).contains(frame.rect), "\(size) at \(frame.scale) is outside the region")
            #expect(abs(frame.rect.midX - region.midX) <= 1 && abs(frame.rect.midY - region.midY) <= 1)
            // It takes the whole width or the whole height, or stops at its own limit.
            #expect(
                abs(frame.rect.width - region.width) <= 1 || abs(frame.rect.height - region.height) <= 1
                    || abs(frame.scale - limit) < 0.001)
        }
    }

    @Test("The canvas is 2880 × 1800 and written as an RGB PNG with no alpha channel")
    func canvasFormat() throws {
        let picture = ScreenshotPicture(
            image: image(1800, 1200, background: (255, 255, 255)), size: CGSize(width: 600, height: 400), cornerRadius: 12,
            maxScale: 2.8)
        let canvas = try ScreenshotComposer.compose(headline: "Set up in a minute", picture: picture)
        #expect(canvas.width == 2880 && canvas.height == 1800)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NameAlert-canvas-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ScreenshotComposer.writePNG(canvas, name: "test", in: directory)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2880)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1800)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        #expect(properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelRGB as String)
        #expect(properties[kCGImagePropertyDepth] as? Int == 8)
        // The PNG's own header: bit depth 8 and color type 2 (RGB), not 6 (RGB with alpha).
        let header = try Data(contentsOf: url)
        #expect(header.count > 26 && header[24] == 8 && header[25] == 2, "bit depth \(header[24]), color type \(header[25])")

        // The corners are the gradient's own colors, and the middle is the picture.
        let pixels = SidebarSelectionRepair.Pixels(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return [Int(pixels.data[offset]), Int(pixels.data[offset + 1]), Int(pixels.data[offset + 2])]
        }
        func isNear(_ actual: [Int], _ expected: [Int], within tolerance: Int = 3) -> Bool {
            zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
        }
        #expect(isNear(rgb(2, 2), [0x4F, 0x46, 0xE5]), "top left: \(rgb(2, 2))")
        #expect(isNear(rgb(2877, 1797), [0x7C, 0x3A, 0xED]), "bottom right: \(rgb(2877, 1797))")
        #expect(rgb(1440, 1040) == [255, 255, 255], "the picture: \(rgb(1440, 1040))")
    }

    // MARK: The switches

    @Test(
        "A switch that is on gets an accent-colored track; its knob, its surroundings and the rest stay as they were",
        arguments: [(255, 216), (221, 184)])
    func switchTrack(background: Int, track: Int) throws {
        let accent = CGColor(srgbRed: 109 / 255, green: 40 / 255, blue: 217 / 255, alpha: 1)
        let page = (UInt8(background), UInt8(background), UInt8(background))
        let source = image(300, 120, background: page) { context in
            fill(context, 50, 25, 120, 50, in: 120, (UInt8(track), UInt8(track), UInt8(track)), radius: 25)  // the track
            fill(context, 105, 29, 60, 42, in: 120, (255, 255, 255), radius: 21)  // the knob, at the right
        }
        let frames = [CGRect(x: 40, y: 20, width: 140, height: 60)]
        let result = try #require(ActiveSwitchLook.recolored(source, frames: frames, scale: 1, accent: accent))
        let pixels = SidebarSelectionRepair.Pixels(result)
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return [Int(pixels.data[offset]), Int(pixels.data[offset + 1]), Int(pixels.data[offset + 2])]
        }
        let track = rgb(65, 50)
        #expect(zip(track, [109, 40, 217]).allSatisfy { abs($0 - $1) <= 2 }, "the track: \(track)")
        #expect(rgb(135, 50) == [255, 255, 255], "the knob")
        #expect(rgb(42, 22) == [background, background, background], "inside the frame, outside the track")
        #expect(rgb(250, 60) == [background, background, background], "outside the frame")
        #expect(ActiveSwitchLook.recolored(source, frames: [], scale: 1, accent: accent) == nil)
    }

    // MARK: The sidebar repair

    private let width = 600, height = 400

    /// A sidebar column: a black selected row, short black strokes (icons) and dark text, on light gray.
    private func sidebar(selected: Bool) -> CGImage {
        image(width, height, background: (246, 246, 246)) { context in
            if selected { fill(context, 20, 100, 320, 64, in: height, (0, 0, 0), radius: 14) }
            fill(context, 40, 40, 30, 3, in: height, (0, 0, 0))  // an icon's stroke, black but short
            fill(context, 40, 300, 30, 3, in: height, (0, 0, 0))
            fill(context, 90, 120, 100, 20, in: height, (40, 40, 40))  // a label, there when the row is not black
            fill(context, 40, 130, 30, 3, in: height, (0, 0, 0))
        }
    }

    @Test("The black row is found as a rectangle, and the short black strokes of icons are not mistaken for it")
    func findsThePill() {
        let pill = SidebarSelectionRepair.blackPill(in: .init(sidebar(selected: true)), searchWidth: 400)
        #expect(pill == SidebarSelectionRepair.Pill(x: 20, y: 100, width: 320, height: 64))
        #expect(SidebarSelectionRepair.blackPill(in: .init(sidebar(selected: false)), searchWidth: 400) == nil)
    }

    @Test("The black row is replaced by the same place in the other render, under a light tint")
    func repairsThePill() throws {
        let tint = CGColor(srgbRed: 0.43, green: 0.16, blue: 0.85, alpha: 1)
        let repaired = try #require(
            SidebarSelectionRepair.repaired(sidebar(selected: true), using: sidebar(selected: false), searchWidth: 400, tint: tint))
        let pixels = SidebarSelectionRepair.Pixels(repaired)
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return [Int(pixels.data[offset]), Int(pixels.data[offset + 1]), Int(pixels.data[offset + 2])]
        }
        #expect(SidebarSelectionRepair.blackPill(in: pixels, searchWidth: 400) == nil, "a black row is left")
        // The row's own label and icon stroke are back, dark.
        #expect(rgb(120, 130).allSatisfy { $0 < 90 }, "the label: \(rgb(120, 130))")
        // The rest of the row is the light background with a tint of the accent: not gray any more, not dark.
        let tinted = rgb(300, 110)
        #expect(tinted[0] < 240 && tinted[2] > tinted[1] + 10 && tinted.allSatisfy { $0 > 200 }, "the row: \(tinted)")
        // What was outside the row is as it was.
        #expect(rgb(45, 41) == [0, 0, 0] && rgb(500, 200) == [246, 246, 246])
    }

    @Test("A render with no black row is left alone")
    func nothingToRepair() {
        let tint = CGColor(srgbRed: 0.43, green: 0.16, blue: 0.85, alpha: 1)
        #expect(SidebarSelectionRepair.repaired(sidebar(selected: false), using: sidebar(selected: false), searchWidth: 400, tint: tint) == nil)
    }
}
