import AppKit
import SwiftUI

/// Renders SwiftUI views to PNG files, so every state of a screen can be looked at before it ships.
///
/// A view is hosted in an offscreen window with `NSHostingView`, drawn with `cacheDisplay(in:to:)` at the screen's
/// scale, and written to `<name>.png` in `$NAMEALERT_RENDER_DIR`, or `build/renders/` in the repository (git-ignored).
/// Pass the variable to `xcodebuild test` as `TEST_RUNNER_NAMEALERT_RENDER_DIR`.
///
/// What it cannot draw: materials and other effects that blur what is behind the window. Give rendered views an
/// opaque background, as the real window's material would be.
@MainActor
enum RenderHarness {
    enum RenderError: Error, CustomStringConvertible {
        case emptySize(String, CGSize)
        case noBitmap(String)
        case noPNG(String)

        var description: String {
            switch self {
            case .emptySize(let name, let size): "\(name): nothing to render at \(size)"
            case .noBitmap(let name): "\(name): could not make a bitmap"
            case .noPNG(let name): "\(name): could not encode the PNG"
            }
        }
    }

    /// Where the PNGs go.
    static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["NAMEALERT_RENDER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return repositoryRoot.appendingPathComponent("build/renders", isDirectory: true)
    }

    /// The repository this file was compiled from.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // NameAlertScreenshots/
        .deletingLastPathComponent()

    /// Renders `view` at `size` points and writes `<name>.png`. Light appearance unless `appearance` says otherwise.
    @discardableResult
    static func render<V: View>(
        _ view: V, size: CGSize, name: String, appearance: NSAppearance.Name = .aqua
    ) throws -> URL {
        guard size.width >= 1, size.height >= 1 else { throw RenderError.emptySize(name, size) }

        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: appearance)
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        settle(hostingView)

        let bounds = hostingView.bounds
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw RenderError.noBitmap(name)
        }
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.noPNG(name) }

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        window.contentView = nil
        return url
    }

    /// Renders `view` at `width` points and the height it asks for.
    @discardableResult
    static func render<V: View>(
        _ view: V, width: CGFloat, name: String, appearance: NSAppearance.Name = .aqua
    ) throws -> URL {
        try render(view, size: fittingSize(of: view, width: width, appearance: appearance), name: name, appearance: appearance)
    }

    /// Renders `view` at the size it asks for.
    @discardableResult
    static func render<V: View>(_ view: V, name: String, appearance: NSAppearance.Name = .aqua) throws -> URL {
        try render(view, size: fittingSize(of: view, width: nil, appearance: appearance), name: name, appearance: appearance)
    }

    /// The size `view` asks for, at `width` if given, rounded up to whole points.
    static func fittingSize<V: View>(of view: V, width: CGFloat?, appearance: NSAppearance.Name = .aqua) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.view.appearance = NSAppearance(named: appearance)
        let proposal = CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let fitting = controller.sizeThatFits(in: proposal)
        return CGSize(width: width ?? ceil(fitting.width), height: ceil(fitting.height))
    }

    /// Lets SwiftUI lay out, run its pending updates and draw before the view is captured.
    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }
}
