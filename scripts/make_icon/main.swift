// Generates the two app icons of Nimb with the halo code of the app itself:
//   Resources/AppIcon.icns        A: the halo on black, as in the reference photo (the file's icon, Finder, Launchpad)
//   Resources/AppIconActive.icns  B: the halo over a dark planet (the Dock icon while DNS is on)
// Run from the repository root:
//   scripts/make_icons.sh
// which compiles this file together with Sources/RDNS/HaloRenderer.swift.
import AppKit

let space = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

/// The rounded tile on the macOS icon grid (an 824 x 824 shape in 1024 x 1024), black with a hairline edge.
func tile(_ ctx: CGContext, _ inner: () -> Void) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(path); ctx.setFillColor(color(0, 0, 0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0.025, 0.025, 0.03), color(0, 0, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    inner()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(3); ctx.setStrokeColor(color(1, 1, 1, 0.2)); ctx.strokePath()
    ctx.restoreGState()
}

func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, alpha), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

/// A: the halo alone, thick and white all the way round, with rays and sparks.
func drawA(_ ctx: CGContext) {
    tile(ctx) {
        let halo = HaloShape(center: CGPoint(x: 512, y: 520), rx: 360, ry: 118, tilt: 0.02, thickness: 1.15)
        halo.draw(ctx, front: false)
        halo.draw(ctx, front: true)
    }
}

/// B: the halo over a dark planet: the planet hides the back half of the ring, the front half is in front of it.
func drawB(_ ctx: CGContext) {
    tile(ctx) {
        let c = CGPoint(x: 512, y: 215), r: CGFloat = 330
        let halo = HaloShape(center: CGPoint(x: 512, y: 570), rx: 330, ry: 98, thickness: 1.2, sparks: 160, rays: 90)
        glow(ctx, at: CGPoint(x: 512, y: 560), radius: 520, alpha: 0.2)
        halo.draw(ctx, front: false)
        // A bare planet: a dark body with a bright rim, so that it reads at small sizes.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); ctx.clip()
        let body = CGGradient(colorsSpace: space, colors: [color(0.16, 0.16, 0.17), color(0.01, 0.01, 0.015)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 512, y: c.y + r), end: CGPoint(x: 512, y: c.y - r * 0.2), options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(color(1, 1, 1, 0.85)); ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        halo.draw(ctx, front: true)
    }
}

func master(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

/// Every size is scaled down from the 1024 master so that the glow keeps the same proportions.
func png(_ image: CGImage, pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func writeIcns(_ image: CGImage, named name: String) throws {
    let fm = FileManager.default
    let iconset = "build/\(name).iconset"
    try? fm.removeItem(atPath: iconset)
    try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    let entries: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (file, pixels) in entries {
        try png(image, pixels: pixels).write(to: URL(fileURLWithPath: "\(iconset)/\(file).png"))
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset, "-o", "Resources/\(name).icns"]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { fatalError("iconutil failed for \(name)") }
}

try FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
try writeIcns(master(drawA), named: "AppIcon")
try writeIcns(master(drawB), named: "AppIconActive")
print("Resources/AppIcon.icns and Resources/AppIconActive.icns written")
