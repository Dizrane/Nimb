import SwiftUI

/// Small deterministic generator so clouds and stars are the same on every launch.
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

/// Everything behind the controls: a sky with clouds while DNS is off, open space while it is on.
/// The colour wash from the first design still floods the scene while services are being checked.
struct WorldBackground: View {
    let mode: AppMode
    let space: Bool

    var body: some View {
        ZStack {
            Theme.base
            SkyScene(space: space)
            SpaceScene(visible: space)
                .opacity(space ? 1 : 0)
            AuroraWash(mode: mode)
                .opacity(mode == .probing || mode == .busy ? 0.85 : (space ? 0.30 : 0))
        }
        .animation(.easeInOut(duration: 1.7), value: space)
        .animation(.easeInOut(duration: 1.0), value: mode)
        .ignoresSafeArea()
    }
}

// MARK: - Sky

private struct Cloud {
    let x: Double, y: Double, scale: Double, speed: Double, alpha: Double
    let puffs: [(dx: Double, dy: Double, r: Double)]

    static let all: [Cloud] = {
        var random = SeededRandom(7)
        var clouds: [Cloud] = []
        // (count, y range, scale range, speed range, alpha range): far, middle and near layers.
        let layers: [(Int, ClosedRange<Double>, ClosedRange<Double>, ClosedRange<Double>, ClosedRange<Double>)] = [
            (6, 150...520, 0.6...0.9, 2...4, 0.34...0.46),
            (6, 120...680, 0.9...1.3, 4...7, 0.50...0.64),
            (5, 380...740, 1.3...1.9, 7...11, 0.68...0.85),
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
    let space: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.09, green: 0.21, blue: 0.50), location: 0),
                    .init(color: Color(red: 0.20, green: 0.43, blue: 0.82), location: 0.42),
                    .init(color: Color(red: 0.56, green: 0.77, blue: 0.97), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Sun glow in the upper corner.
            RadialGradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.78).opacity(0.42), .clear],
                           center: UnitPoint(x: 0.88, y: 0.12), startRadius: 0, endRadius: 330)
            clouds
                .offset(y: space ? 260 : 0)
                .opacity(space ? 0 : 1)
        }
        .opacity(space ? 0 : 1)
    }

    private var clouds: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: space || reduceMotion || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let span = size.width + 560
                for cloud in Cloud.all {
                    let cx = (cloud.x + t * cloud.speed).truncatingRemainder(dividingBy: span) - 280
                    for puff in cloud.puffs {
                        let center = CGPoint(x: cx + puff.dx * cloud.scale, y: cloud.y + puff.dy * cloud.scale)
                        let radius = puff.r * cloud.scale
                        let shade = CGPoint(x: center.x, y: center.y + radius * 0.22)
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: shade.x - radius, y: shade.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [Color(red: 0.50, green: 0.60, blue: 0.82).opacity(cloud.alpha * 0.55), .clear]),
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

// MARK: - Space

private struct Star {
    let x: Double, y: Double, size: Double, phase: Double, speed: Double, bright: Bool

    static let all: [Star] = {
        var random = SeededRandom(21)
        return (0..<150).map { i in
            Star(x: random.next(), y: random.next(), size: random.next(0.7...1.9), phase: random.next(0...6.28),
                 speed: random.next(0.6...2.2), bright: i % 17 == 0)
        }
    }()
}

private struct SpaceScene: View {
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.01, green: 0.02, blue: 0.06), Color(red: 0.03, green: 0.05, blue: 0.15), Color(red: 0.06, green: 0.06, blue: 0.22)],
                startPoint: .top, endPoint: .bottom
            )
            // Faint nebula.
            RadialGradient(colors: [Color(red: 0.35, green: 0.25, blue: 0.85).opacity(0.28), .clear],
                           center: UnitPoint(x: 0.15, y: 0.78), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [Color(red: 0.10, green: 0.55, blue: 0.85).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.92, y: 0.40), startRadius: 0, endRadius: 280)
            stars
        }
    }

    private var stars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !visible || reduceMotion || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for star in Star.all {
                    let twinkle = 0.55 + 0.45 * sin(t * star.speed + star.phase)
                    let p = CGPoint(x: star.x * size.width, y: star.y * size.height)
                    let r = star.size * (star.bright ? 1.7 : 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)),
                             with: .color(.white.opacity(twinkle * (star.bright ? 1 : 0.8))))
                    if star.bright {
                        var cross = Path()
                        cross.move(to: CGPoint(x: p.x - 6, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 6, y: p.y))
                        cross.move(to: CGPoint(x: p.x, y: p.y - 6)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 6))
                        ctx.stroke(cross, with: .color(.white.opacity(twinkle * 0.45)), lineWidth: 0.8)
                    }
                }
                // A shooting star every few seconds.
                let cycle = t.truncatingRemainder(dividingBy: 11)
                if cycle < 0.9 {
                    let k = cycle / 0.9
                    let head = CGPoint(x: size.width * (0.15 + 0.5 * k), y: size.height * (0.06 + 0.16 * k))
                    var tail = Path()
                    tail.move(to: head)
                    tail.addLine(to: CGPoint(x: head.x - 46, y: head.y - 15))
                    ctx.stroke(tail, with: .color(.white.opacity(0.8 * (1 - k))), lineWidth: 1.4)
                }
            }
        }
    }
}

// MARK: - Colour wash

/// Slowly drifting colour clouds; they take over while services are being checked.
struct AuroraWash: View {
    let mode: AppMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // The wash only drifts, so it needs few frames unless it is the star of the show.
        TimelineView(.animation(minimumInterval: 1.0 / (mode == .probing || mode == .busy ? 15 : 5), paused: reduceMotion || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                cloud(mode.accent, size: 360, x: sin(t * 0.17) * 90 - 60, y: -250 + cos(t * 0.13) * 40, opacity: 0.55)
                cloud(mode.secondary, size: 420, x: cos(t * 0.11) * 110 + 90, y: -90 + sin(t * 0.15) * 60, opacity: 0.48)
                cloud(mode.accent, size: 300, x: sin(t * 0.09 + 2) * 120, y: 300 + cos(t * 0.12) * 40, opacity: 0.30)
            }
            .animation(.easeInOut(duration: 1.2), value: mode)
        }
        .allowsHitTesting(false)
    }

    private func cloud(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        // A radial gradient looks like a blurred disc but costs far less to draw.
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.5), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size * 0.62))
            .frame(width: size * 1.25, height: size * 1.25)
            .offset(x: x, y: y)
    }
}
