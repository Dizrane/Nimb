import SwiftUI

/// The motion of the YouTube and Discord scene, ported from `art-studio/deliver/media-motion/media-motion.js`: sound arcs from the
/// Discord mark, a glint over the glass of the screen with a flare of the play button, and a blink of the mark.
/// Nothing is pre-rendered: a few strokes and gradients per frame.
enum MediaMotion {
    /// Points on the 160 x 132 pt picture of the scene (origin at its top left).
    private static let mark = CGPoint(x: 111.2, y: 90)
    private static let play = CGPoint(x: 77.6, y: 58)
    private static let eyes = [CGPoint(x: 103.3, y: 89.0), CGPoint(x: 119.1, y: 89.0)]
    private static let eyeRadius = (x: 3.7, y: 5.0)
    private static let display = CGRect(x: 35.2, y: 29.2, width: 124.8 - 35.2, height: 88.4 - 29.2)
    private static let displayRadius: CGFloat = 13.6
    private static let eyePearl = 212.0
    /// How strong the sound and the glint are: the quiet values the user chose.
    private static let sound = 0.5
    private static let glint = 0.55

    /// `origin` is where the top left of the scene picture is on the stage, `t` the clock in seconds, `lit` 0...1.
    static func draw(in ctx: inout GraphicsContext, origin: CGPoint, t: Double, lit: Double) {
        guard lit > 0.003 else { return }
        func S(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
        let m = S(mark), pl = S(play)

        ctx.drawLayer { layer in
            layer.blendMode = .screen

            // 1. Sound: three arcs, 2.8 s per wave, radius 30 to 60 around the mark, from -20 to +54 degrees.
            for i in 0..<3 {
                let phase = ((t / 2.8) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let r = 30 + 30 * phase
                let alpha = pow(sin(.pi * phase), 1.3) * 0.55 * lit * sound
                var arc = Path()
                let steps = 14
                for k in 0...steps {
                    let a = -0.35 + (0.95 + 0.35) * Double(k) / Double(steps)
                    let point = CGPoint(x: m.x + r * cos(a), y: m.y + r * sin(a))
                    if k == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
                }
                layer.stroke(arc, with: .color(.white.opacity(alpha)),
                             style: StrokeStyle(lineWidth: (1.5 - 0.8 * phase) * (0.7 + 0.3 * sound), lineCap: .round))
            }

            // 2. Glint: every 5.2 s, in the first 34 % of the period, a band 32 pt wide, tilted by 0.45 rad, crosses the glass.
            let q = ((t.truncatingRemainder(dividingBy: 5.2)) / 5.2) / 0.34
            if q < 1 {
                let d0 = S(display.origin)
                let glass = CGRect(x: d0.x, y: d0.y, width: display.width, height: display.height)
                let eased = q * q * (3 - 2 * q)
                let cx = glass.minX - 30 + (glass.width + 60) * eased
                layer.drawLayer { band in
                    band.clip(to: Path(roundedRect: glass, cornerRadius: displayRadius))
                    band.translateBy(x: cx, y: glass.midY)
                    band.rotate(by: .radians(0.45))
                    band.fill(Path(CGRect(x: -16, y: -120, width: 32, height: 240)),
                              with: .linearGradient(Gradient(stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0.20 * lit * glint), location: 0.5),
                                .init(color: .white.opacity(0), location: 1),
                              ]), startPoint: CGPoint(x: -16, y: 0), endPoint: CGPoint(x: 16, y: 0)))
                }
                // The play button flares as the band passes.
                let flare = 0.35 * exp(-pow((cx - pl.x) / 22, 2)) * lit * glint
                layer.fill(Path(ellipseIn: CGRect(x: pl.x - 26, y: pl.y - 26, width: 52, height: 52)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(flare), .white.opacity(0)]), center: pl, startRadius: 0, endRadius: 26))
            }
        }

        // 3. Blink: every 3.9 s the eyes close for 0.2 s (a pearl lid grows over each eye and opens again).
        let b = t.truncatingRemainder(dividingBy: 3.9)
        let closed = b > 3.62 ? sin(.pi * min(max((b - 3.62) / 0.2, 0), 1)) : 0
        if closed > 0.02 {
            let v = (eyePearl * (0.30 + 0.70 * lit)) / 255
            for eye in eyes {
                let p = S(eye)
                let ry = (eyeRadius.y + 0.6) * closed
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - (eyeRadius.x + 0.6), y: p.y - ry, width: 2 * (eyeRadius.x + 0.6), height: 2 * ry)),
                         with: .color(Color(white: v)))
            }
        }
    }
}
