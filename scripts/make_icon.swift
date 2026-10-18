// Generates Resources/AppIcon.icns: Nimb, a glowing halo on black (black and white, like a long-exposure photo).
// Run from the repository root: swift scripts/make_icon.swift
import AppKit

let size = 1024
let outDir = "Resources"
let iconset = "build/AppIcon.iconset"
let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, alpha), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

struct RNG {
    var s: UInt64
    mutating func next() -> CGFloat {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(s >> 33) / CGFloat(1 << 31)
    }
}

func ellipsePath(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, tilt: CGFloat = 0) -> CGPath {
    let path = CGMutablePath()
    var a: CGFloat = 0
    var first = true
    while a <= .pi * 2 + 0.0001 {
        let x = rx * cos(a), y = ry * sin(a)
        let p = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        a += 0.02
    }
    return path
}

/// A bright ring seen at a shallow angle: stacked bloom, a crisp double core, sparks along it and a flare on the far edge.
func halo(_ ctx: CGContext, center c: CGPoint, rx: CGFloat, ry: CGFloat, tilt: CGFloat) {
    ctx.setLineCap(.round)
    for (w, a) in zip([78, 52, 34, 22, 13, 7] as [CGFloat], [0.035, 0.055, 0.085, 0.14, 0.26, 0.5] as [CGFloat]) {
        ctx.setStrokeColor(color(1, 1, 1, a)); ctx.setLineWidth(w)
        ctx.addPath(ellipsePath(c, rx, ry, tilt: tilt)); ctx.strokePath()
    }
    ctx.setStrokeColor(color(1, 1, 1, 0.95)); ctx.setLineWidth(8)
    ctx.addPath(ellipsePath(c, rx, ry, tilt: tilt)); ctx.strokePath()
    ctx.setStrokeColor(color(1, 1, 1, 0.7)); ctx.setLineWidth(3)
    ctx.addPath(ellipsePath(c, rx * 0.93, ry * 0.9, tilt: tilt)); ctx.strokePath()

    var rng = RNG(s: 11)
    for _ in 0..<150 {
        let a = rng.next() * .pi * 2
        let off = (rng.next() - 0.5) * 34
        let len = 8 + rng.next() * 42
        let x = (rx + off) * cos(a), y = (ry + off * 0.4) * sin(a)
        let p = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        ctx.setStrokeColor(color(1, 1, 1, 0.15 + rng.next() * 0.55))
        ctx.setLineWidth(1 + rng.next() * 2)
        ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x - sin(a) * len, y: p.y + cos(a) * len * (ry / rx))); ctx.strokePath()
    }

    let top = CGPoint(x: c.x, y: c.y + ry)
    glow(ctx, at: top, radius: 90, alpha: 0.85)
    ctx.saveGState()
    ctx.translateBy(x: top.x, y: top.y)
    ctx.scaleBy(x: 5.5, y: 1)
    glow(ctx, at: .zero, radius: 70, alpha: 0.42)
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(path); ctx.setFillColor(color(0, 0, 0)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let base = CGGradient(colorsSpace: space, colors: [color(0.02, 0.02, 0.025), color(0, 0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    halo(ctx, center: CGPoint(x: 512, y: 520), rx: 318, ry: 108, tilt: 0.03)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(3); ctx.setStrokeColor(color(1, 1, 1, 0.2)); ctx.strokePath()
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
