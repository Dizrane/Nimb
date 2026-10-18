// Generates Resources/AppIcon.icns: the planet with Russia lit up, a satellite and its signal.
// Run from the repository root: swift scripts/make_icon.swift   (reads Resources/world.json)
import AppKit

let size = 1024
let outDir = "Resources"
let iconset = "build/AppIcon.iconset"
let space = CGColorSpaceCreateDeviceRGB()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func glow(_ ctx: CGContext, at center: CGPoint, radius: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: [color(r, g, b, alpha), color(r, g, b, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: Map

struct World {
    let land: [[Double]]
    let russia: [[Double]]

    static func load() -> World {
        guard let data = FileManager.default.contents(atPath: "Resources/world.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let land = json["land"] as? [[Double]],
              let regions = json["regions"] as? [String: [[Double]]],
              let russia = regions["ru"] else {
            fatalError("Resources/world.json not found: run from the repository root")
        }
        return World(land: land, russia: russia)
    }
}

/// Same orthographic projection as Sources/RDNS/WorldMap.swift.
struct Orthographic {
    let sinLat0: Double, cosLat0: Double, lon0: Double
    init(lon0: Double, lat0: Double) {
        self.lon0 = lon0 * .pi / 180
        sinLat0 = sin(lat0 * .pi / 180)
        cosLat0 = cos(lat0 * .pi / 180)
    }
    func project(lon: Double, lat: Double) -> (x: Double, y: Double, visible: Bool) {
        let phi = lat * .pi / 180, dl = lon * .pi / 180 - lon0
        let cosC = sinLat0 * sin(phi) + cosLat0 * cos(phi) * cos(dl)
        var x = cos(phi) * sin(dl), y = cosLat0 * sin(phi) - sinLat0 * cos(phi) * cos(dl)
        if cosC < 0 {
            let length = max((x * x + y * y).squareRoot(), 1e-9)
            x /= length; y /= length
        }
        return (x, y, cosC >= 0)
    }
}

func ringsPath(_ rings: [[Double]], _ view: Orthographic, center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for ring in rings {
        var points: [CGPoint] = []
        var anyVisible = false
        for i in stride(from: 0, to: ring.count - 1, by: 2) {
            let p = view.project(lon: ring[i], lat: ring[i + 1])
            if p.visible { anyVisible = true }
            points.append(CGPoint(x: center.x + CGFloat(p.x) * radius, y: center.y + CGFloat(p.y) * radius))
        }
        guard anyVisible, points.count > 2 else { continue }
        path.addLines(between: points)
        path.closeSubpath()
    }
    return path
}

func graticule(_ view: Orthographic, center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    func add(_ coordinates: [(Double, Double)]) {
        var drawing = false
        for (lon, lat) in coordinates {
            let p = view.project(lon: lon, lat: lat)
            let point = CGPoint(x: center.x + CGFloat(p.x) * radius, y: center.y + CGFloat(p.y) * radius)
            if p.visible {
                if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
            } else { drawing = false }
        }
    }
    for lon in stride(from: -180.0, to: 180.0, by: 30.0) { add(stride(from: -90.0, through: 90.0, by: 4.0).map { (lon, $0) }) }
    for lat in stride(from: -60.0, through: 60.0, by: 30.0) { add(stride(from: -180.0, through: 180.0, by: 4.0).map { ($0, lat) }) }
    return path
}

// MARK: Drawing

func drawSatellite(_ ctx: CGContext, at p: CGPoint, scale: CGFloat, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: scale, y: scale)
    let panel = color(0.12, 0.26, 0.64), edge = color(0.62, 0.82, 1.0)
    for x in [CGFloat(-23), CGFloat(8)] {
        let rect = CGRect(x: x, y: -4, width: 15, height: 8)
        ctx.setFillColor(panel)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(color(0.62, 0.82, 1.0, 0.5)); ctx.setLineWidth(0.5)
        for i in 1..<4 {
            ctx.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.maxY))
        }
        ctx.move(to: CGPoint(x: rect.minX, y: 0)); ctx.addLine(to: CGPoint(x: rect.maxX, y: 0))
        ctx.strokePath()
        ctx.setStrokeColor(edge); ctx.setLineWidth(0.8)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)); ctx.strokePath()
    }
    ctx.setStrokeColor(color(1, 1, 1, 0.85)); ctx.setLineWidth(1.1)
    ctx.move(to: CGPoint(x: -8, y: 0)); ctx.addLine(to: CGPoint(x: -5, y: 0))
    ctx.move(to: CGPoint(x: 5, y: 0)); ctx.addLine(to: CGPoint(x: 8, y: 0))
    ctx.strokePath()
    let body = CGPath(roundedRect: CGRect(x: -5, y: -5, width: 10, height: 10), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let metal = CGGradient(colorsSpace: space, colors: [color(0.98, 0.98, 0.98), color(0.66, 0.68, 0.72)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: -5, y: 5), end: CGPoint(x: 5, y: -5), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(1, 1, 1, 0.9)); ctx.setLineWidth(0.6)
    ctx.addPath(body); ctx.strokePath()
    // Antenna with a glowing tip, pointing down at the planet.
    glow(ctx, at: CGPoint(x: 0, y: -9), radius: 9, r: 0.3, g: 1.0, b: 0.75, alpha: 0.85)
    ctx.setStrokeColor(color(1, 1, 1, 0.95)); ctx.setLineWidth(1.1)
    ctx.move(to: CGPoint(x: 0, y: -5)); ctx.addLine(to: CGPoint(x: 0, y: -8.5)); ctx.strokePath()
    ctx.setFillColor(color(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: -1.8, y: -11, width: 3.6, height: 3.6))
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext, world: World) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let accent = (r: CGFloat(0.22), g: CGFloat(0.92), b: CGFloat(0.64))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(path); ctx.setFillColor(color(0.02, 0.03, 0.08)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()

    // Deep space.
    let base = CGGradient(colorsSpace: space, colors: [color(0.01, 0.02, 0.07), color(0.05, 0.05, 0.20)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    glow(ctx, at: CGPoint(x: 220, y: 300), radius: 420, r: 0.35, g: 0.25, b: 0.90, alpha: 0.38)
    glow(ctx, at: CGPoint(x: 850, y: 780), radius: 380, r: 0.10, g: 0.55, b: 0.90, alpha: 0.28)

    // Stars.
    var seed: UInt64 = 5
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for i in 0..<70 {
        let p = CGPoint(x: 120 + random() * 784, y: 120 + random() * 784)
        let r = 1.6 + random() * 3.2
        ctx.setFillColor(color(1, 1, 1, 0.35 + random() * 0.6))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        if i % 14 == 0 {
            ctx.setStrokeColor(color(1, 1, 1, 0.5)); ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: p.x - 14, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 14, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - 14)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 14))
            ctx.strokePath()
        }
    }

    // Planet.
    let center = CGPoint(x: 490, y: 440), radius: CGFloat = 285
    let view = Orthographic(lon0: 72, lat0: 49)
    let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    glow(ctx, at: center, radius: radius * 1.55, r: accent.r, g: accent.g, b: accent.b, alpha: 0.55)

    ctx.saveGState()
    ctx.addEllipse(in: disc); ctx.clip()
    let ocean = CGGradient(colorsSpace: space, colors: [color(0.12, 0.36, 0.66), color(0.02, 0.07, 0.24)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ocean, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(1.6)
    ctx.addPath(graticule(view, center: center, radius: radius)); ctx.strokePath()
    let land = ringsPath(world.land, view, center: center, radius: radius)
    ctx.setFillColor(color(0.17, 0.34, 0.45)); ctx.addPath(land); ctx.fillPath()
    ctx.setStrokeColor(color(1, 1, 1, 0.20)); ctx.setLineWidth(1.4); ctx.addPath(land); ctx.strokePath()
    let russia = ringsPath(world.russia, view, center: center, radius: radius)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: color(accent.r, accent.g, accent.b, 0.95))
    ctx.setFillColor(color(accent.r, accent.g, accent.b, 0.95)); ctx.addPath(russia); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(color(1, 1, 1, 0.85)); ctx.setLineWidth(2.2); ctx.addPath(russia); ctx.strokePath()
    // Night side.
    let night = CGGradient(colorsSpace: space, colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.62)] as CFArray, locations: [0.32, 1])!
    ctx.drawLinearGradient(night, start: CGPoint(x: disc.minX + 120, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
    ctx.restoreGState()
    ctx.setLineWidth(4); ctx.setStrokeColor(color(1, 1, 1, 0.55)); ctx.strokeEllipse(in: disc.insetBy(dx: 2, dy: 2))

    // Signal from the satellite to Moscow.
    let moscow = view.project(lon: 37.6, lat: 55.75)
    let target = CGPoint(x: center.x + CGFloat(moscow.x) * radius, y: center.y + CGFloat(moscow.y) * radius)
    let sat = CGPoint(x: 790, y: 790)
    let dx = target.x - sat.x, dy = target.y - sat.y
    let length = (dx * dx + dy * dy).squareRoot()
    let nx = -dy / length * 26, ny = dx / length * 26
    ctx.saveGState()
    ctx.move(to: sat)
    ctx.addLine(to: CGPoint(x: target.x + nx, y: target.y + ny))
    ctx.addLine(to: CGPoint(x: target.x - nx, y: target.y - ny))
    ctx.closePath(); ctx.clip()
    let beam = CGGradient(colorsSpace: space, colors: [color(accent.r, accent.g, accent.b, 0.60), color(accent.r, accent.g, accent.b, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(beam, start: sat, end: target, options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(1, 1, 1, 0.9)); ctx.setLineWidth(4); ctx.setLineDash(phase: 0, lengths: [5, 15]); ctx.setLineCap(.round)
    ctx.move(to: sat); ctx.addLine(to: target); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setStrokeColor(color(1, 1, 1, 0.8)); ctx.setLineWidth(3.5)
    ctx.strokeEllipse(in: CGRect(x: target.x - 24, y: target.y - 24, width: 48, height: 48))
    ctx.setFillColor(color(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: target.x - 9, y: target.y - 9, width: 18, height: 18))

    drawSatellite(ctx, at: sat, scale: 4.4, angle: -0.5)

    // Gloss over the top of the tile.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 40, y: 700, width: 944, height: 500)); ctx.clip()
    let gloss = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 700), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(3); ctx.setStrokeColor(color(1, 1, 1, 0.22)); ctx.strokePath()
    ctx.restoreGState()
}

func renderPNG(pixels: Int, world: World) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / CGFloat(size), y: CGFloat(pixels) / CGFloat(size))
    drawIcon(in: ctx, world: world)
    return rep.representation(using: .png, properties: [:])!
}

let world = World.load()
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
    try renderPNG(pixels: px, world: world).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
