#!/usr/bin/env swift
//
// generate_icon.swift
//
// Renders the NameAlert app icon with Core Graphics only (no SF Symbols, no text, no network)
// on the macOS Big Sur+ icon grid, then produces every size the asset catalog needs.
//
//   swift scripts/generate_icon.swift <outdir>
//
// Writes into <outdir>:
//   icon_1024.png                          master render (1024 x 1024, sRGB, transparent margin)
//   icon_16x16.png ... icon_512x512@2x.png the ten macOS sizes, downscaled from the master with `sips -z`
//   Contents.json                          mac-idiom manifest for AppIcon.appiconset
//
// If <outdir> is itself an `.appiconset`, no separate icon_1024.png is written: `icon_512x512@2x.png`
// is the same image, and an icon set must hold only files its Contents.json lists.
//
// Design (spec section 13): 824 x 824 continuous-corner body centred on the 1024 canvas, soft drop
// shadow inside the canvas, indigo -> violet gradient, a white speech bubble with a tail at the
// bottom-left, three sound-wave arcs to its right and a red alert dot at the top-right.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants (1024 canvas, y grows downward)

enum Design {
    static let canvas: CGFloat = 1024

    // Body: the Big Sur grid, 824 pt rounded square centred on the canvas.
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let bodyRadius: CGFloat = 185
    static let bodySmoothing: CGFloat = 0.6

    static let indigo: UInt32 = 0x4F46E5
    static let violet: UInt32 = 0x7C3AED
    static let alertRed: UInt32 = 0xEF4444
    /// Mid-gradient colour used under the body gradient so antialiased edge pixels never show a fringe.
    static let bodyUnderfill: UInt32 = 0x6844E6

    // Body drop shadow (blur 20, 12 pt down, 30 % black).
    static let bodyShadowBlur: CGFloat = 20
    static let bodyShadowDrop: CGFloat = 12
    static let bodyShadowAlpha: CGFloat = 0.30

    // Speech bubble.
    static let bubble = CGRect(x: 222, y: 376, width: 384, height: 296)
    static let bubbleRadius: CGFloat = 104
    static let bubbleSmoothing: CGFloat = 0.40
    static let tailRoot: CGFloat = 124        // distance from the bubble's left edge to where the tail leaves the bottom edge
    static let tailDrop: CGFloat = 96         // how far the tip hangs below the bubble
    static let tailTipRadius: CGFloat = 13
    static let tailLead: CGFloat = 46         // straight run before the tip, so the tip can be rounded by a tangent arc
    static let tailSwoosh: CGFloat = 56       // handle length of the concave curve where the tail leaves the bottom edge

    // Sound waves, concentric about a point inside the bubble's right side.
    static let waveCenter = CGPoint(x: 538, y: 524)
    static let waveRadii: [CGFloat] = [124, 202, 280]
    static let waveAlphas: [CGFloat] = [1.0, 0.78, 0.56]
    static let waveWidth: CGFloat = 46
    static let waveHalfAngle: CGFloat = 30 * .pi / 180

    // Alert dot.
    static let dotCenter = CGPoint(x: 782, y: 240)
    static let dotRadius: CGFloat = 72
    static let dotRing: CGFloat = 6

    // Shadow cast by the whole glyph onto the body.
    static let glyphShadowBlur: CGFloat = 30
    static let glyphShadowDrop: CGFloat = 16
    static let glyphShadowAlpha: CGFloat = 0.34
}

// MARK: - Colour helpers

func makeSRGB() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: makeSRGB(),
        colors: stops.map(\.0) as CFArray,
        locations: stops.map(\.1)
    )!
}

// MARK: - Continuous-corner rounded rectangle

/// Apple-style "squircle" corner: a circular arc blended into the straight edges with cubic
/// curves so curvature changes gradually (same construction as Figma's corner smoothing).
struct CornerProfile {
    /// Where the curve leaves the straight edge, measured from the corner point.
    let inset: CGFloat
    /// Three cubic segments for the top-right corner in a frame whose origin is the corner
    /// point (x right, y down). The curve runs from (-inset, 0) to (0, inset).
    let cubics: [(c1: CGPoint, c2: CGPoint, end: CGPoint)]

    init(radius r: CGFloat, smoothing xi: CGFloat) {
        func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
        let p = (1 + xi) * r
        let arcMeasure = 90 * (1 - xi)
        let chord = sin(rad(arcMeasure / 2)) * r * 2.0.squareRoot()
        let straightening = (90 - arcMeasure) / 2
        let p3p4 = r * tan(rad(straightening / 2))
        let beta = 45 * xi
        let c = p3p4 * cos(rad(beta))
        let d = c * tan(rad(beta))
        let b = (p - chord - c - d) / 3
        let a = 2 * b

        let start = CGPoint(x: -p, y: 0)
        let e1 = CGPoint(x: start.x + a + b + c, y: d)
        let e2 = CGPoint(x: e1.x + chord, y: e1.y + chord)

        // The circular part as one cubic (it spans at most 90 degrees).
        let centre = CGPoint(x: -r, y: r)
        let t1 = atan2(e1.y - centre.y, e1.x - centre.x)
        let t2 = atan2(e2.y - centre.y, e2.x - centre.x)
        let k = 4.0 / 3.0 * tan((t2 - t1) / 4)
        let arc1 = CGPoint(x: e1.x - k * r * sin(t1), y: e1.y + k * r * cos(t1))
        let arc2 = CGPoint(x: e2.x + k * r * sin(t2), y: e2.y - k * r * cos(t2))

        inset = p
        cubics = [
            (CGPoint(x: start.x + a, y: 0), CGPoint(x: start.x + a + b, y: 0), e1),
            (arc1, arc2, e2),
            (CGPoint(x: e2.x + d, y: e2.y + c), CGPoint(x: e2.x + d, y: e2.y + b + c), CGPoint(x: e2.x + d, y: e2.y + a + b + c)),
        ]
    }

    /// Maps a point of the canonical top-right corner onto corner `index`
    /// (0 top-right, 1 bottom-right, 2 bottom-left, 3 top-left) of `rect`.
    private func map(_ q: CGPoint, corner index: Int, in rect: CGRect) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: rect.maxX + q.x, y: rect.minY + q.y)
        case 1: return CGPoint(x: rect.maxX - q.y, y: rect.maxY + q.x)
        case 2: return CGPoint(x: rect.minX - q.x, y: rect.maxY - q.y)
        default: return CGPoint(x: rect.minX + q.y, y: rect.minY - q.x)
        }
    }

    /// Appends a line to the start of the corner followed by the corner curve itself.
    func append(to path: CGMutablePath, rect: CGRect, corner index: Int) {
        path.addLine(to: map(CGPoint(x: -inset, y: 0), corner: index, in: rect))
        for cubic in cubics {
            path.addCurve(
                to: map(cubic.end, corner: index, in: rect),
                control1: map(cubic.c1, corner: index, in: rect),
                control2: map(cubic.c2, corner: index, in: rect)
            )
        }
    }
}

func continuousRoundedRect(_ rect: CGRect, radius: CGFloat, smoothing: CGFloat) -> CGPath {
    let profile = CornerProfile(radius: radius, smoothing: smoothing)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + profile.inset, y: rect.minY))
    for corner in 0..<4 { profile.append(to: path, rect: rect, corner: corner) }
    path.closeSubpath()
    return path
}

// MARK: - Speech bubble

/// Rounded bubble whose bottom-left corner is replaced by a tail that hangs below it.
func speechBubblePath() -> CGPath {
    let rect = Design.bubble
    let profile = CornerProfile(radius: Design.bubbleRadius, smoothing: Design.bubbleSmoothing)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + profile.inset, y: rect.minY))
    profile.append(to: path, rect: rect, corner: 0)
    profile.append(to: path, rect: rect, corner: 1)

    let root = CGPoint(x: rect.minX + Design.tailRoot, y: rect.maxY)
    let tip = CGPoint(x: rect.minX, y: rect.maxY + Design.tailDrop)
    // The tail's inner edge is a concave swoosh from the bottom edge that ends in a short straight
    // run toward the tip (direction `towardRoot`, unit-ish), so a tangent arc can round the tip.
    let towardRoot = CGPoint(x: 0.66, y: -0.75)
    let lead = CGPoint(x: tip.x + towardRoot.x * Design.tailLead, y: tip.y + towardRoot.y * Design.tailLead)

    path.addLine(to: root)
    path.addCurve(
        to: lead,
        control1: CGPoint(x: root.x - Design.tailSwoosh, y: root.y),
        control2: CGPoint(x: lead.x + towardRoot.x * 34, y: lead.y + towardRoot.y * 34)
    )
    // Round the tip, then run straight up the left edge (any point above the tip on its vertical works).
    path.addArc(
        tangent1End: tip,
        tangent2End: CGPoint(x: tip.x, y: tip.y - 100),
        radius: Design.tailTipRadius
    )
    profile.append(to: path, rect: rect, corner: 3)
    path.closeSubpath()
    return path
}

// MARK: - Rendering

func renderMaster() -> CGImage {
    let side = Int(Design.canvas)
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: makeSRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create bitmap context") }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Draw with a top-left origin like the numbers above. Note: CG shadow offsets are specified in
    // base space and ignore the CTM, so a negative height is "down" on screen despite this flip.
    ctx.translateBy(x: 0, y: Design.canvas)
    ctx.scaleBy(x: 1, y: -1)

    let body = continuousRoundedRect(Design.body, radius: Design.bodyRadius, smoothing: Design.bodySmoothing)

    // 1. Drop shadow of the body (the gradient below is painted over this fill).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -Design.bodyShadowDrop),
        blur: Design.bodyShadowBlur,
        color: color(0x000000, alpha: Design.bodyShadowAlpha)
    )
    ctx.setFillColor(color(Design.bodyUnderfill))
    ctx.addPath(body)
    ctx.fillPath()
    ctx.restoreGState()

    let top = Design.body.minY
    let bottom = Design.body.maxY
    let midX = Design.body.midX

    // 2. Body gradient and lighting, clipped to the body.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(color(Design.indigo), 0), (color(Design.violet), 1)]),
        start: CGPoint(x: midX, y: top), end: CGPoint(x: midX, y: bottom), options: []
    )
    // Subtle top highlight.
    ctx.drawRadialGradient(
        gradient([(color(0xFFFFFF, alpha: 0.13), 0), (color(0xFFFFFF, alpha: 0), 1)]),
        startCenter: CGPoint(x: midX, y: top - 60), startRadius: 0,
        endCenter: CGPoint(x: midX, y: top - 60), endRadius: 620, options: []
    )
    ctx.restoreGState()

    // 3. Glyph: bubble, waves and dot, composited as one layer so they share one soft shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -Design.glyphShadowDrop),
        blur: Design.glyphShadowBlur,
        color: color(0x1E1065, alpha: Design.glyphShadowAlpha)
    )
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Bubble.
    let bubble = speechBubblePath()
    ctx.saveGState()
    ctx.addPath(bubble)
    ctx.clip()
    let bubbleBox = bubble.boundingBoxOfPath
    ctx.drawLinearGradient(
        gradient([(color(0xFFFFFF), 0), (color(0xEDE9FE), 1)]),
        start: CGPoint(x: bubbleBox.midX, y: bubbleBox.minY),
        end: CGPoint(x: bubbleBox.midX, y: bubbleBox.maxY), options: []
    )
    ctx.restoreGState()

    // Waves.
    ctx.setLineWidth(Design.waveWidth)
    ctx.setLineCap(.round)
    for (radius, alpha) in zip(Design.waveRadii, Design.waveAlphas) {
        ctx.setStrokeColor(color(0xFFFFFF, alpha: alpha))
        ctx.addArc(
            center: Design.waveCenter, radius: radius,
            startAngle: -Design.waveHalfAngle, endAngle: Design.waveHalfAngle, clockwise: false
        )
        ctx.strokePath()
    }

    // Alert dot with a white ring.
    let outer = Design.dotRadius + Design.dotRing
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(
        x: Design.dotCenter.x - outer, y: Design.dotCenter.y - outer, width: outer * 2, height: outer * 2))
    let dotRect = CGRect(
        x: Design.dotCenter.x - Design.dotRadius, y: Design.dotCenter.y - Design.dotRadius,
        width: Design.dotRadius * 2, height: Design.dotRadius * 2)
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    // #EF4444 at the centre; a whisper of lighter above and deeper below, kept close to flat.
    ctx.drawLinearGradient(
        gradient([(color(0xF24E4E), 0), (color(Design.alertRed), 0.5), (color(0xE83C3C), 1)]),
        start: CGPoint(x: dotRect.midX, y: dotRect.minY), end: CGPoint(x: dotRect.midX, y: dotRect.maxY), options: []
    )
    ctx.restoreGState()

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 4. Rim light: a hairline highlight on the upper inner edge, a faint shade on the lower one.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.addPath(body)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(color(0xFFFFFF, alpha: 0.30), 0), (color(0xFFFFFF, alpha: 0), 1)]),
        start: CGPoint(x: midX, y: top), end: CGPoint(x: midX, y: top + 360), options: []
    )
    ctx.drawLinearGradient(
        gradient([(color(0x000000, alpha: 0), 0), (color(0x000000, alpha: 0.18), 1)]),
        start: CGPoint(x: midX, y: bottom - 320), end: CGPoint(x: midX, y: bottom), options: []
    )
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("could not snapshot the bitmap") }
    return image
}

// MARK: - Output

struct IconFile {
    let name: String
    let pixels: Int
    let size: String
    let scale: String
}

enum Output {
    static let files: [IconFile] = [
        IconFile(name: "icon_16x16.png", pixels: 16, size: "16x16", scale: "1x"),
        IconFile(name: "icon_16x16@2x.png", pixels: 32, size: "16x16", scale: "2x"),
        IconFile(name: "icon_32x32.png", pixels: 32, size: "32x32", scale: "1x"),
        IconFile(name: "icon_32x32@2x.png", pixels: 64, size: "32x32", scale: "2x"),
        IconFile(name: "icon_128x128.png", pixels: 128, size: "128x128", scale: "1x"),
        IconFile(name: "icon_128x128@2x.png", pixels: 256, size: "128x128", scale: "2x"),
        IconFile(name: "icon_256x256.png", pixels: 256, size: "256x256", scale: "1x"),
        IconFile(name: "icon_256x256@2x.png", pixels: 512, size: "256x256", scale: "2x"),
        IconFile(name: "icon_512x512.png", pixels: 512, size: "512x512", scale: "1x"),
        IconFile(name: "icon_512x512@2x.png", pixels: 1024, size: "512x512", scale: "2x"),
    ]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate_icon: \(message)\n".utf8))
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("cannot create \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func run(_ executable: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { fail("cannot launch \(executable): \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

func generate(into outputPath: String) {
    let fileManager = FileManager.default
    let outDir = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
    do { try fileManager.createDirectory(at: outDir, withIntermediateDirectories: true) } catch {
        fail("cannot create \(outDir.path): \(error)")
    }

    // The master is `icon_1024.png`, except inside an .appiconset, where the 1024 px entry of the set
    // (`icon_512x512@2x.png`) is the master and no extra file is left behind.
    let keepMaster = outDir.pathExtension != "appiconset"
    let master = outDir.appendingPathComponent(keepMaster ? "icon_1024.png" : "icon_512x512@2x.png")
    writePNG(renderMaster(), to: master)

    // One sips run per distinct pixel size; files that share a size are copies of the first one.
    var rendered: [Int: URL] = [Int(Design.canvas): master]
    for file in Output.files {
        let destination = outDir.appendingPathComponent(file.name)
        if destination == master { continue }
        try? fileManager.removeItem(at: destination)
        if let existing = rendered[file.pixels] {
            do { try fileManager.copyItem(at: existing, to: destination) } catch { fail("cannot copy \(file.name): \(error)") }
        } else {
            run("/usr/bin/sips", ["-z", "\(file.pixels)", "\(file.pixels)", master.path, "--out", destination.path])
            rendered[file.pixels] = destination
        }
    }

    let images: [[String: String]] = Output.files.map {
        ["filename": $0.name, "idiom": "mac", "scale": $0.scale, "size": $0.size]
    }
    let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    do {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: outDir.appendingPathComponent("Contents.json"))
    } catch {
        fail("cannot write Contents.json: \(error)")
    }

    print("wrote \(Output.files.count) icons + Contents.json" + (keepMaster ? " + icon_1024.png" : "") + " to \(outDir.path)")
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
    FileHandle.standardError.write(Data("usage: swift scripts/generate_icon.swift <outdir>\n".utf8))
    exit(2)
}
generate(into: arguments[1])
