import Foundation

/// The lazy flight of the paper plane: a port of `art-studio/deliver/paper-plane/wander.js` (points and seconds, y down).
///
/// A small simulation, not a formula: the plane flies at a nearly constant speed, its heading turns by a smooth signal that
/// never repeats, and near the edge of its area it is steered back to the middle, so it never stops, never snaps round and
/// never leaves the stage. `step(_:)` once per frame, then read x, y, heading, bank, z and band.
final class Wanderer {
    struct Params {
        var ax = 165.0, ay = 56.0, cy = -8.0, speed = 17.0, turn = 0.32
    }

    // Depth: from time to time a new level; the plane crosses to the other side of the figure only far out at the side.
    private let levels = [-0.9, -0.35, 0.35, 0.9]
    private let weights = [0.3, 0.2, 0.2, 0.3]
    private let dwell = (5.0, 12.0)
    private let outsideLimit = 82.0
    private let depthRate = 0.7
    private let speedGain = 0.25

    private let p: Params
    private let s: [Double]
    private var randomState: UInt32

    var t = 0.0
    var x: Double
    var y: Double
    /// Direction of flight in radians (0 = to the right, positive = clockwise on the screen).
    var heading: Double
    private var rate = 0.0
    /// Roll in degrees (positive = turning right).
    var bank = 0.0
    private var speed: Double
    /// Depth: -1 far behind the figure ... +1 far in front of it.
    var z = -0.35
    private var zTarget = -0.35
    private var nextChange = 4.0
    /// The layer to draw it in: 0 behind the back half of the halo, 1 between that and the figure, 2 between the figure and the
    /// front half of the halo, 3 in front of everything.
    var band = 1

    init(params: Params = Params(), seed: Double = 0) {
        p = params
        s = [1.3, 4.1, 2.2, 5.6].map { $0 * (1 + seed) }
        randomState = UInt32(truncatingIfNeeded: Int(seed * 1000 + 12345))
        x = -0.6 * params.ax
        y = params.cy
        heading = -0.3 + seed
        speed = params.speed
    }

    /// A tiny deterministic generator (mulberry32), so that the same seed gives the same flight.
    private func random() -> Double {
        randomState = randomState &+ 0x6D2B79F5
        var v = randomState
        v = (v ^ (v >> 15)) &* (v | 1)
        v ^= v &+ ((v ^ (v >> 7)) &* (v | 61))
        return Double(v ^ (v >> 14)) / 4294967296.0
    }

    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(max(v, a), b) }
    private func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double { let u = clamp((v - a) / (b - a), 0, 1); return u * u * (3 - 2 * u) }
    private func wrap(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
    private func pickLevel() -> Double {
        let r = random()
        var acc = 0.0
        for i in levels.indices {
            acc += weights[i]
            if r <= acc { return levels[i] }
        }
        return levels[levels.count - 1]
    }
    private func sign(_ v: Double) -> Double { v < 0 ? -1 : (v > 0 ? 1 : 0) }
    private func band(for z: Double) -> Int { z < -0.55 ? 0 : (z < 0 ? 1 : (z < 0.55 ? 2 : 3)) }

    func step(_ dt: Double) {
        let n = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            t += h
            // The free will of the plane: three slow waves of turning.
            var omega = p.turn * (0.55 * sin(0.31 * t + s[0]) + 0.35 * sin(0.77 * t + s[1]) + 0.20 * sin(1.43 * t + s[2]))
            // Near the edge of its area: turn towards the middle, the harder the closer to the edge.
            let dx = x, dy = y - p.cy
            let r2 = (dx / p.ax) * (dx / p.ax) + (dy / p.ay) * (dy / p.ay)
            if r2 > 0.3 {
                let want = atan2(-dy, -dx), err = wrap(want - heading)
                omega += clamp(err * 1.5, -1.6, 1.6) * smooth(0.3, 0.85, r2)
            }
            heading += omega * h

            // Depth.
            let outside = abs(x) > outsideLimit
            if t >= nextChange {
                let target = pickLevel()
                let crosses = sign(target) != sign(z) || sign(target) != sign(zTarget)
                if !crosses || outside {
                    zTarget = target
                    nextChange = t + dwell.0 + random() * (dwell.1 - dwell.0)
                } else {
                    nextChange = t + 0.5
                }
            }
            let crossingNeeded = sign(zTarget) != sign(z)
            if !crossingNeeded || outside || abs(z) > 0.45 { z += (zTarget - z) * (1 - exp(-h / depthRate)) }
            band = band(for: z)
            speed = p.speed * (1 + 0.22 * sin(0.29 * t + s[3])) * (1 + speedGain * z)
            x += cos(heading) * speed * h
            y += sin(heading) * speed * h
            rate += (omega - rate) * (1 - exp(-h / 0.35))
            let target = clamp(rate * 26, -34, 34)
            bank += (target - bank) * (1 - exp(-h / 0.30))
        }
    }
}
