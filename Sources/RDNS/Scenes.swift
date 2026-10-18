import SwiftUI

/// Everything behind the controls, in black and white. Off: a grey sky with drifting clouds.
/// On: the clouds sink away and open space with still stars is left.
struct NimbBackground: View {
    let lit: Bool

    var body: some View {
        ZStack {
            Theme.base
            SkyScene(lit: lit)
            // The light of the halo spills onto the dark.
            RadialGradient(colors: [Color.white.opacity(lit ? 0.17 : 0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 0.13), startRadius: 0, endRadius: 300)
            Stars()
                .opacity(lit ? 1 : 0)
            RadialGradient(colors: [.clear, Color.black.opacity(lit ? 0.7 : 0.45)], center: .center, startRadius: 240, endRadius: 520)
        }
        .animation(.easeInOut(duration: 1.7), value: lit)
        .ignoresSafeArea()
    }
}

/// Still star dust. It is drawn once, so it costs nothing while the window is open.
private struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            var state: UInt64 = 21
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 33) / Double(1 << 31)
            }
            for _ in 0..<70 {
                let p = CGPoint(x: next() * size.width, y: next() * size.height)
                let r = 0.5 + next() * 1.1
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)),
                         with: .color(.white.opacity(0.10 + next() * 0.32)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Clouds

/// Small deterministic generator so the clouds are the same on every launch.
private struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(1 << 31)
    }

    mutating func next(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}

private struct Cloud {
    let x: Double, y: Double, scale: Double, speed: Double, alpha: Double
    let puffs: [(dx: Double, dy: Double, r: Double)]

    static let all: [Cloud] = {
        var random = SeededRandom(7)
        var clouds: [Cloud] = []
        // (count, y range, scale range, speed range, alpha range): far, middle and near layers.
        let layers: [(Int, ClosedRange<Double>, ClosedRange<Double>, ClosedRange<Double>, ClosedRange<Double>)] = [
            (6, 150...520, 0.6...0.9, 2...4, 0.30...0.42),
            (6, 120...680, 0.9...1.3, 4...7, 0.42...0.58),
            (5, 380...740, 1.3...1.9, 7...11, 0.58...0.78),
        ]
        for (count, ys, scales, speeds, alphas) in layers {
            for _ in 0..<count {
                var puffs: [(Double, Double, Double)] = []
                for i in 0..<8 {
                    let t = Double(i) / 7
                    puffs.append((dx: (t - 0.5) * 150 + random.next(-12...12),
                                  dy: random.next(-14...10) - sin(t * .pi) * 16,
                                  r: random.next(32...54) * (0.75 + sin(t * .pi) * 0.55)))
                }
                clouds.append(Cloud(x: random.next(0...1000), y: random.next(ys), scale: random.next(scales),
                                    speed: random.next(speeds), alpha: random.next(alphas), puffs: puffs))
            }
        }
        return clouds
    }()
}

private struct SkyScene: View {
    let lit: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // A grey sky, dark enough at the top for white text, paler towards the horizon.
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.06), location: 0),
                    .init(color: Color(white: 0.20), location: 0.42),
                    .init(color: Color(white: 0.46), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            clouds
                .offset(y: lit ? 260 : 0)
                .opacity(lit ? 0 : 1)
        }
        .opacity(lit ? 0 : 1)
    }

    private var clouds: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: lit || reduceMotion || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let span = size.width + 560
                for cloud in Cloud.all {
                    let cx = (cloud.x + t * cloud.speed).truncatingRemainder(dividingBy: span) - 280
                    for puff in cloud.puffs {
                        let center = CGPoint(x: cx + puff.dx * cloud.scale, y: cloud.y + puff.dy * cloud.scale)
                        let radius = puff.r * cloud.scale
                        // A darker underside gives the cloud volume.
                        let shade = CGPoint(x: center.x, y: center.y + radius * 0.22)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: shade.x - radius, y: shade.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [Color(white: 0.35).opacity(cloud.alpha * 0.55), .clear]),
                                center: shade, startRadius: 0, endRadius: radius
                            )
                        )
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [.white.opacity(cloud.alpha), .white.opacity(cloud.alpha * 0.62), .white.opacity(0)]),
                                center: CGPoint(x: center.x, y: center.y - radius * 0.12), startRadius: 0, endRadius: radius
                            )
                        )
                    }
                }
            }
        }
    }
}
