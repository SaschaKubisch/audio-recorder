// SPDX-License-Identifier: MIT
// Draws the app icon (a red dot on a dark disc, on a dark rounded square)
// and writes an .iconset folder. build.sh turns it into AppIcon.icns with iconutil.
//
// Usage: make-icon <output.iconset>

import AppKit

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let gfx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gfx
    let ctx = gfx.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Work on a 1024 unit canvas and scale to the requested size.
    let s = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: the body is 824 units wide, centred, with room for a shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // Body gradient (dark graphite).
    ctx.saveGState()
    bodyPath.addClip()
    let bodyGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.27, alpha: 1),
        NSColor(calibratedWhite: 0.11, alpha: 1),
    ])!
    bodyGradient.draw(in: body, angle: -90)
    ctx.restoreGState()

    // Thin inner highlight on the body edge.
    ctx.saveGState()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    edge.lineWidth = 4
    edge.stroke()
    ctx.restoreGState()

    // Dark disc.
    let center = CGPoint(x: 512, y: 512)
    let discRadius: CGFloat = 300
    let disc = NSBezierPath(ovalIn: CGRect(x: center.x - discRadius, y: center.y - discRadius,
                                           width: discRadius * 2, height: discRadius * 2))
    ctx.saveGState()
    disc.addClip()
    NSGradient(colors: [
        NSColor(calibratedWhite: 0.05, alpha: 1),
        NSColor(calibratedWhite: 0.16, alpha: 1),
    ])!.draw(in: disc.bounds, angle: 90)
    ctx.restoreGState()
    NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
    disc.lineWidth = 6
    disc.stroke()

    // Red dot.
    let dotRadius: CGFloat = 168
    let dot = NSBezierPath(ovalIn: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                          width: dotRadius * 2, height: dotRadius * 2))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor(calibratedRed: 1, green: 0.1, blue: 0.1, alpha: 0.55).cgColor)
    NSColor(calibratedRed: 0.93, green: 0.13, blue: 0.14, alpha: 1).setFill()
    dot.fill()
    ctx.restoreGState()

    ctx.saveGState()
    dot.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.33, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.80, green: 0.07, blue: 0.09, alpha: 1),
    ])!.draw(in: dot.bounds, angle: -90)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Names and pixel sizes iconutil expects.
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
    guard let data = drawIcon(pixels: px) else {
        FileHandle.standardError.write(Data("Could not render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
