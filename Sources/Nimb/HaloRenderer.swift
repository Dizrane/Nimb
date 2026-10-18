import CoreGraphics

// The halo of Nimb, drawn with Core Graphics after a long-exposure photo of a glowing ring: a thick band that is
// white along its whole length (widest at the near, upper edge), a thin second ring inside it, fine concentric
// streaks, a soft bloom, rays and sparks. The same code draws it in the window and in the app icons
// (scripts/make_icon/main.swift is compiled together with this file).
//
// Depth: the upper half of the ring is nearer to the viewer, the lower half is behind. Draw the back half
// first, then the planet, then the front half.

private let haloColorSpace = CGColorSpaceCreateDeviceRGB()

private func haloWhite(_ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: haloColorSpace, components: [1, 1, 1, alpha])!
}

private func haloGlow(_ ctx: CGContext, at center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let gradient = CGGradient(colorsSpace: haloColorSpace, colors: [haloWhite(alpha), haloWhite(0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

private struct HaloRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + next() * (high - low) }
}

struct HaloShape {
    var center: CGPoint
    var rx: CGFloat
    var ry: CGFloat
    var tilt: CGFloat = 0
    /// Multiplier of the band width in the photo.
    var thickness: CGFloat = 1
    var sparks = 220
    var rays = 130
    var flare: CGFloat = 1

    /// Point on the ellipse (y up), rotated by the tilt.
    func point(_ angle: CGFloat, scale: CGFloat = 1, shift: CGFloat = 0) -> CGPoint {
        let x = rx * scale * cos(angle), y = ry * scale * sin(angle) + shift
        return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
    }

    /// Band width: widest at the near (upper) and left edge, thin at the far (lower) edge, like in the photo.
    func width(_ angle: CGFloat) -> CGFloat {
        let front = 0.5 * (1 + sin(angle)), left = 0.5 * (1 - cos(angle))
        return rx * (0.034 + 0.062 * front + 0.03 * left * front) * thickness
    }

    func ribbon(from a0: CGFloat, to a1: CGFloat, widthScale: CGFloat = 1, scale: CGFloat = 1, shift: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let steps = max(Int((a1 - a0) / 0.02), 2)
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0...steps {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            let p = point(a, scale: scale, shift: shift)
            // Outward normal of the ellipse.
            var nx = ry * cos(a), ny = rx * sin(a)
            let length = max((nx * nx + ny * ny).squareRoot(), 1e-6)
            nx /= length; ny /= length
            let rnx = nx * cos(tilt) - ny * sin(tilt), rny = nx * sin(tilt) + ny * cos(tilt)
            let w = width(a) * widthScale / 2
            outer.append(CGPoint(x: p.x + rnx * w, y: p.y + rny * w))
            inner.append(CGPoint(x: p.x - rnx * w, y: p.y - rny * w))
        }
        path.addLines(between: outer)
        path.addLines(between: inner.reversed())
        path.closeSubpath()
        return path
    }

    /// One half of the halo. `front` is the upper (nearer) half, otherwise the lower half behind the planet.
    func draw(_ ctx: CGContext, front: Bool, dim: CGFloat = 1) {
        let a0: CGFloat = front ? 0 : .pi, a1: CGFloat = front ? .pi : .pi * 2
        let half: CGFloat = front ? 1 : 0.6 * dim

        ctx.saveGState()
        // Bloom: shadows of the band at several radii give a real glow, widest first.
        for (blur, alpha, widthScale) in [(rx * 0.9, 0.55, 1.6), (rx * 0.45, 0.7, 1.3), (rx * 0.2, 0.9, 1.0), (rx * 0.08, 1.0, 0.8)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: haloWhite(alpha * half))
            ctx.setFillColor(haloWhite(0.6 * half))
            ctx.addPath(ribbon(from: a0, to: a1, widthScale: widthScale * 0.6)); ctx.fillPath()
            ctx.restoreGState()
        }
        // The band itself, blown out to white with soft edges, and the thin inner ring just inside it.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: rx * 0.035, color: haloWhite(half))
        ctx.setFillColor(haloWhite(0.99 * half))
        ctx.addPath(ribbon(from: a0, to: a1, widthScale: 0.9)); ctx.fillPath()
        ctx.setFillColor(haloWhite(0.6 * half))
        ctx.addPath(ribbon(from: a0, to: a1, widthScale: 0.16, scale: 0.9, shift: -ry * 0.07)); ctx.fillPath()
        ctx.restoreGState()

        // Fine concentric streaks inside the band, like a long exposure.
        var random = HaloRandom(state: front ? 5 : 6)
        for _ in 0..<26 {
            let scale = random.range(0.9, 0.995)
            ctx.setStrokeColor(haloWhite(random.range(0.12, 0.4) * half)); ctx.setLineWidth(max(random.range(0.8, 2) * rx / 200, 0.5))
            let from = random.range(a0, a1 - 0.5), to = from + random.range(0.4, 1.5)
            let path = CGMutablePath()
            var a = from
            var first = true
            while a <= min(to, a1) {
                let p = point(a, scale: scale)
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                a += 0.03
            }
            ctx.addPath(path); ctx.strokePath()
        }

        // Rays fanning outwards, longer along the horizontal.
        for _ in 0..<rays {
            let a = random.range(a0, a1)
            let p = point(a, scale: 1.03)
            let reach = random.range(0.15, 1.1) * rx * (0.5 + 0.7 * abs(cos(a)))
            let direction = CGPoint(x: cos(a), y: sin(a) * 0.45)
            ctx.setStrokeColor(haloWhite(random.range(0.03, 0.13) * half)); ctx.setLineWidth(max(random.range(0.8, 1.6) * rx / 200, 0.5))
            ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + direction.x * reach, y: p.y + direction.y * reach)); ctx.strokePath()
        }
        // Sparks on the outer edge, thicker on the right as in the photo.
        for _ in 0..<(sparks / 2) {
            let a = random.next() < 0.6 ? random.range(max(a0, -0.5), min(a1, 1.3)) : random.range(a0, a1)
            guard a >= a0 && a <= a1 else { continue }
            let offset = random.range(0, 0.07) * rx
            let p = point(a, scale: 1 + offset / rx)
            let length = random.range(0.02, 0.16) * rx
            ctx.setStrokeColor(haloWhite(random.range(0.15, 0.75) * half)); ctx.setLineWidth(max(random.range(0.8, 2.4) * rx / 200, 0.5))
            ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x - sin(a) * length, y: p.y + cos(a) * length * ry / rx)); ctx.strokePath()
        }
        ctx.restoreGState()

        if front {
            // The hot zone at the near edge and long horizontal streaks to the left and right of the ring.
            let top = point(.pi / 2 + 0.05)
            haloGlow(ctx, at: top, radius: rx * 0.13, alpha: 1.0 * flare)
            ctx.saveGState()
            ctx.translateBy(x: top.x, y: top.y)
            ctx.scaleBy(x: 1, y: 0.09)
            haloGlow(ctx, at: .zero, radius: rx * 0.55, alpha: 0.9 * flare)
            ctx.restoreGState()
            for side in [-1.0, 1.0] as [CGFloat] {
                let start = CGPoint(x: center.x + side * rx * 0.93, y: center.y + ry * 0.05)
                let end = CGPoint(x: center.x + side * rx * 2.0, y: center.y + ry * 0.05)
                let gradient = CGGradient(colorsSpace: haloColorSpace, colors: [haloWhite(0.5 * flare), haloWhite(0)] as CFArray, locations: [0, 1])!
                for (height, alpha) in [(rx * 0.03, 0.8), (rx * 0.012, 1.0)] as [(CGFloat, CGFloat)] {
                    ctx.saveGState()
                    ctx.addRect(CGRect(x: min(start.x, end.x), y: start.y - height / 2, width: abs(end.x - start.x), height: height)); ctx.clip()
                    ctx.setAlpha(alpha)
                    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
                    ctx.restoreGState()
                }
            }
        }
    }
}

/// The two halves of the window's halo, rendered once: drawing the bloom live every frame would be far too costly.
final class HaloImages {
    static let shared = HaloImages()

    /// Pixels per point of the rendered images.
    let pixelScale: CGFloat = 2
    /// Radii of the ring in points.
    let rx: CGFloat = 80
    let ry: CGFloat = 21
    /// Size of each image in points; the ring is in the middle.
    let size: CGSize
    let back: CGImage
    let front: CGImage

    private init() {
        size = CGSize(width: rx * 4.2, height: ry * 2 + rx * 1.9)
        let pixelSize = CGSize(width: size.width * pixelScale, height: size.height * pixelScale)
        let shape = HaloShape(center: CGPoint(x: pixelSize.width / 2, y: pixelSize.height / 2),
                              rx: rx * pixelScale, ry: ry * pixelScale, thickness: 1, sparks: 90, rays: 110)
        func render(front: Bool) -> CGImage {
            let ctx = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: haloColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            shape.draw(ctx, front: front)
            return ctx.makeImage()!
        }
        back = render(front: false)
        front = render(front: true)
    }
}
