// Generates Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

let size = 1024
let outDir = "Resources"
let iconset = "build/AppIcon.iconset"

func drawIcon(in ctx: CGContext) {
    let canvas = CGFloat(size)
    // Apple's macOS icon grid: 824x824 shape centred in 1024x1024.
    let shape = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: shape, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark gradient tile.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.13, green: 0.17, blue: 0.24, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: canvas - 100), end: CGPoint(x: 0, y: 100), options: [])

    // Green button disc with glow, like the app's big button.
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let radius: CGFloat = 270
    ctx.setShadow(offset: .zero, blur: 90, color: CGColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 0.65))
    let disc = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.35, green: 0.90, blue: 0.50, alpha: 1),
        CGColor(red: 0.12, green: 0.68, blue: 0.34, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.clip()
    ctx.drawLinearGradient(disc, start: CGPoint(x: 0, y: center.y + radius), end: CGPoint(x: 0, y: center.y - radius), options: [])
    ctx.restoreGState()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // White power glyph: open ring + vertical bar.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(44)
    ctx.setLineCap(.round)
    let ring: CGFloat = 130
    // Gap at the top (y is up): from upper-left, the long way round, to upper-right.
    ctx.addArc(center: center, radius: ring, startAngle: .pi / 2 + 0.6,
               endAngle: .pi / 2 - 0.6, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: center.x, y: center.y + 20))
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + ring + 40))
    ctx.strokePath()

    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / CGFloat(size), y: CGFloat(pixels) / CGFloat(size))
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try renderPNG(pixels: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
