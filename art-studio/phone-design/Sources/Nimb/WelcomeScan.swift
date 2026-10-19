import SwiftUI

/// The "scan" of the welcome step, ported from `art-studio/deliver/icon-welcome/scan.js` (points, y down, the middle of the disc is
/// (0, 0)): the small halo goes down through the black disc and back, and what the ring has passed turns into something else.
/// Taps alternate: odd = to the middle of the disc, where static noise appears behind the ring and the ring shudders; even = to
/// the lower edge, where everything the ring has passed becomes the planet and turns black again on the way back.
enum WelcomeScan {
    static let radius = 30.0
    /// Height of the centre of the ring above the middle of the disc at rest, and the scale of the halo then.
    static let rest = -36.4
    static let restScale = 0.38
    /// How much wider the ring gets where it goes through the disc.
    static let hug = 0.14
    static let yMid = 0.0, yEdge = 28.2
    static let down = 1.8, hold = 2.0, up = 1.8
    static var total: Double { down + hold + up }

    enum Mode { case middle, edge }

    struct Ring {
        var y: Double, scale: Double, rx: Double, ry: Double
    }

    /// Zero speed and zero acceleration at both ends: the motion has no jerk.
    static func smoother(_ u: Double) -> Double { u * u * u * (u * (u * 6 - 15) + 10) }

    static func ring(_ p: Double, _ mode: Mode) -> Ring {
        let y1 = mode == .middle ? yMid : yEdge
        let y = rest + (y1 - rest) * p
        let a = abs(y) / radius
        let bump = a < 1 ? pow(cos(.pi / 2 * a), 2) : 0
        let scale = restScale * (1 + hug * bump)
        let rx = 80 * scale
        return Ring(y: y, scale: scale, rx: rx, ry: rx * 0.3125)
    }

    /// Progress over time: down, hold at the lowest point, up. `t` is in seconds since the tap.
    static func progress(_ t: Double) -> Double {
        if t < down { return smoother(t / down) }
        if t < down + hold { return 1 }
        if t < total { return 1 - smoother((t - down - hold) / up) }
        return 0
    }

    /// The border of what the ring has passed: the near (upper) arc of the ring, so the planet starts exactly at the bright line.
    static func arcY(_ x: Double, _ r: Ring) -> Double {
        let e = min(abs(x) / r.rx, 1)
        return r.y - r.ry * (1 - e * e).squareRoot()
    }

    /// The hash behind the noise: a number 0..<1 for a place and a moment.
    static func random(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263 &+ c &* 1_274_126_177)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }

    /// The static noise of the middle tap, per point that has been passed.
    static func noise(x: Double, y: Double, t: Double, p: Double) -> (grey: Double, alpha: Double) {
        let frame = Int(t * 30)
        let n = random(Int(x), Int(y), frame)
        let tear = random(Int((y / 2).rounded(.down)), 7, frame) > 0.93
        let gain = (0.55 + 0.45 * pow(sin(t * 6.3), 2)) * min(p * 2.5, 1)
        return (tear ? 235 : n * 230, min((tear ? 1.0 : 0.9) * gain, 1))
    }

    /// The ring shudders while it rests in the middle tap.
    static func shudder(_ t: Double) -> CGPoint {
        let k = Int(t * 24)
        return CGPoint(x: (random(k, 1, 2) - 0.5) * 0.8, y: (random(k, 2, 3) - 0.5) * 0.4)
    }
}
