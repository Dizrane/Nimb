import SwiftUI

/// The main button. Off: the page is the large button alone. On: the button settles under the planet, which comes up with a glowing
/// halo over it, the region of the chosen provider lit up and a satellite sending it a signal.
struct HeroButton: View {
    let mode: AppMode
    let lit: Bool
    let region: Region
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var gate = AnimationGate.shared
    @StateObject private var hover = Flag()
    @StateObject private var state: HeroState

    private let radius: CGFloat = 66

    init(mode: AppMode, lit: Bool, region: Region, action: @escaping () -> Void) {
        self.mode = mode
        self.lit = lit
        self.region = region
        self.action = action
        _state = StateObject(wrappedValue: HeroState(region: region, lit: lit))
    }

    var body: some View {
        // A paused timeline keeps the picture of the moment it stopped, which may be one from before the switch; a paused planet is
        // drawn from the time of now every time something changes, and the end of the movement is a change too.
        let planetRuns = !reduceMotion && gate.shouldRun(brief: state.moving)
        let signalRuns = !reduceMotion && (lit || mode == .probing || state.moving) && gate.shouldRun(brief: state.moving)
        Button(action: action) {
            ZStack {
                // While it turns the planet is drawn as often as the screen allows; while it only drifts, 20 times a second (a slower
                // clock shows as steps on the edge of the continents); with DNS off it is hardly seen and drawn rarely.
                TimelineView(.animation(minimumInterval: state.moving ? 1.0 / 60 : (lit ? 1.0 / 20 : 1.0 / 6), paused: !planetRuns)) { context in
                    canvas(.planet, planetRuns ? context.date : Date())
                }
                TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !signalRuns)) { context in
                    canvas(.signal, signalRuns ? context.date : Date())
                }
                // One button: it lights up where it is, then settles under the planet as the small button of the lit state.
                PowerButton(progress: lit ? 1 : 0, hover: hover.value ? 1 : 0, busy: mode == .busy, restY: PowerButton.restY, settledY: PowerButton.settledY)
                    .powerButtonAnimation(on: lit, hovering: hover.value)
            }
            .frame(width: 320, height: HeroLayout.stageHeight)
            .contentShape(Path(ellipseIn: CGRect(x: 70, y: 30, width: 180, height: 176)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0; state.setHover($0) }
        .onChange(of: region) { state.retarget($0) }
        .onChange(of: lit) { state.setLit($0) }
    }

    private func canvas(_ part: GlobeCanvas.Part, _ date: Date) -> some View {
        GlobeCanvas(
            part: part,
            t: reduceMotion ? 0 : date.timeIntervalSinceReferenceDate,
            center: state.center(at: date),
            region: region,
            lit: state.lit(at: date),
            satellite: state.satellite(at: date),
            mode: mode,
            hover: state.hover(at: date),
            radius: radius
        )
    }
}

/// Time-based state of the hero: which way the planet faces, how lit it is and where the satellite is.
final class HeroState: ObservableObject {
    @Published private(set) var moving = false

    private var from: (lon: Double, lat: Double)
    private var to: (lon: Double, lat: Double)
    private var turnStarted = Date.distantPast
    private let turnDuration = 1.6

    private var litTarget: Double
    private var litFrom: Double
    private var litStarted = Date.distantPast
    private let litDuration = 1.2

    private var hoverFrom = 0.0
    private var hoverTarget = 0.0
    private var hoverStarted = Date.distantPast

    private var satelliteFrom: Double
    private var satelliteStarted = Date.distantPast
    private let satelliteInTime = 2.6
    private let satelliteOutTime = 0.8

    init(region: Region, lit: Bool) {
        from = region.view
        to = region.view
        // Opening with DNS already on plays the "switch on" scene once.
        litTarget = 0
        litFrom = 0
        satelliteFrom = 0
        if lit { setLit(true) }
    }

    func center(at date: Date) -> (lon: Double, lat: Double) {
        let p = min(max(date.timeIntervalSince(turnStarted) / turnDuration, 0), 1)
        let eased = p * p * (3 - 2 * p)
        var dLon = to.lon - from.lon
        while dLon > 180 { dLon -= 360 }
        while dLon < -180 { dLon += 360 }
        return (from.lon + dLon * eased, from.lat + (to.lat - from.lat) * eased)
    }

    /// 0 dark, 1 fully lit.
    func lit(at date: Date) -> Double {
        let p = min(max(date.timeIntervalSince(litStarted) / litDuration, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return litFrom + (litTarget - litFrom) * eased
    }

    /// 0 gone, 1 at its station. It flies in after the halo lights up and leaves faster than it came.
    func satellite(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(satelliteStarted)
        if litTarget > 0.5 {
            return min(max(satelliteFrom + max(elapsed - 0.25, 0) / satelliteInTime, 0), 1)
        }
        return min(max(satelliteFrom - elapsed / satelliteOutTime, 0), 1)
    }

    /// 0 resting, 1 pointer over the button; eased over half a second so that nothing jumps.
    func hover(at date: Date) -> Double {
        let p = min(max(date.timeIntervalSince(hoverStarted) / 0.5, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return hoverFrom + (hoverTarget - hoverFrom) * eased
    }

    func setHover(_ over: Bool) {
        let now = Date()
        hoverFrom = hover(at: now)
        hoverTarget = over ? 1 : 0
        hoverStarted = now
        keepMoving(for: 0.6)
    }

    func retarget(_ region: Region) {
        let now = Date()
        from = center(at: now)
        to = region.view
        turnStarted = now
        keepMoving(for: turnDuration)
    }

    func setLit(_ on: Bool) {
        let now = Date()
        let current = lit(at: now)
        satelliteFrom = satellite(at: now)
        litFrom = current
        litTarget = on ? 1 : 0
        // The planet comes up while the button is on its way (`PowerButton`); switching off it goes at once.
        let delay = on ? 0.5 : 0
        litStarted = now.addingTimeInterval(delay)
        satelliteStarted = now.addingTimeInterval(delay)
        keepMoving(for: delay + (on ? 0.25 + satelliteInTime + 0.2 : litDuration + 0.2))
    }

    private var movingUntil = Date.distantPast

    /// Keeps the fast redraw rate on until the given time, however many animations overlap.
    private func keepMoving(for seconds: Double) {
        movingUntil = max(movingUntil, Date().addingTimeInterval(seconds))
        moving = true
        scheduleCheck()
    }

    private func scheduleCheck() {
        let delay = max(movingUntil.timeIntervalSinceNow, 0) + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if Date() >= self.movingUntil { self.moving = false } else { self.scheduleCheck() }
        }
    }
}

private struct GlobeCanvas: View {
    enum Part { case planet, signal }

    let part: Part
    let t: Double
    let center: (lon: Double, lat: Double)
    let region: Region
    let lit: Double
    let satellite: Double
    let mode: AppMode
    let hover: Double
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            // The same height as the figure of the other pages (`HeroLayout`).
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 2)
            let r = radius * (0.88 + 0.12 * lit)
            let view = Orthographic(lon0: center.lon + sin(t * 0.15) * 8, lat0: center.lat + sin(t * 0.1) * 3)
            let world = WorldMap.shared
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let white = Color.white
            // The light of the satellite on the region: it reaches the planet as the satellite comes to its station.
            let beam = min(max((satellite - 0.6) / 0.4, 0), 1)

            // The halo: resting in the middle among the clouds while off, crowning the planet while on.
            let spin: Double = mode == .probing ? 3.0 : mode == .busy ? 2.0 : 1.0
            let pulse = mode == .busy ? 0.75 + 0.25 * sin(t * 5) : 1
            let strength = lit * pulse
            let placement = haloPlacement(c: c, r: r, lit: lit)

            func screen(_ p: (x: Double, y: Double, visible: Bool)) -> CGPoint {
                CGPoint(x: c.x + CGFloat(p.x) * r, y: c.y - CGFloat(p.y) * r)
            }

            if part == .planet {
                if strength > 0.01 { HaloArt.draw(.back, in: &ctx, center: placement.center, scale: placement.scale, opacity: strength) }
                ctx.drawLayer { ctx in
                ctx.opacity = lit
                // Faint atmosphere, stronger when lit.
                ctx.fill(
                    Path(ellipseIn: disc.insetBy(dx: -r * 0.6, dy: -r * 0.6)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: white.opacity(0), location: 0),
                            .init(color: white.opacity(0.03 + 0.10 * lit + 0.06 * hover * lit), location: 0.62),
                            .init(color: white.opacity(0), location: 1),
                        ]),
                        center: c, startRadius: 0, endRadius: r * 1.6
                    )
                )

                ctx.drawLayer { l in
                    l.clip(to: Path(ellipseIn: disc))
                    l.fill(
                        Path(disc),
                        with: .linearGradient(
                            Gradient(colors: [Color(white: 0.11), Color(white: 0.01)]),
                            startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)
                        )
                    )
                    l.stroke(graticule(view, screen), with: .color(white.opacity(0.06 + 0.04 * lit)), lineWidth: 0.5)

                    let land = path(world.land, view, screen)
                    l.fill(land, with: .color(white.opacity(0.10 + 0.08 * lit)))
                    l.stroke(land, with: .color(white.opacity(0.22 + 0.12 * lit)), lineWidth: 0.5)

                    // The region of the chosen provider: a faint outline until the satellite lights it, then white.
                    let highlighted = path(world.rings(for: region), view, screen)
                    // The glow of the region is two soft strokes under the fill: a blur filter on a big path on every frame is what
                    // made this page the most expensive one.
                    l.stroke(highlighted, with: .color(white.opacity(0.09 * beam)), style: StrokeStyle(lineWidth: 7, lineJoin: .round))
                    l.stroke(highlighted, with: .color(white.opacity(0.14 * beam)), style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
                    l.fill(highlighted, with: .color(white.opacity(0.10 + 0.55 * beam)))
                    l.stroke(highlighted, with: .color(.white.opacity(0.35 + 0.25 * beam)), lineWidth: 0.7)

                    // Night side.
                    l.fill(
                        Path(disc),
                        with: .linearGradient(
                            Gradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color.black.opacity(0.65), location: 1)]),
                            startPoint: CGPoint(x: disc.minX + r * 0.5, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)
                        )
                    )
                }
                ctx.stroke(
                    Path(ellipseIn: disc),
                    with: .linearGradient(Gradient(colors: [white.opacity(0.25 + 0.3 * lit + 0.15 * hover * lit), white.opacity(0.03)]),
                                          startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)),
                    lineWidth: 1
                )
                }
            }

            if part == .signal {
                // Scanning with DNS off: rings spread out from the button.
                if mode == .probing && lit < 0.5 {
                    for k in 0..<3 {
                        let phase = (t * 0.6 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                        let ringRadius = 64 + 56 * phase
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringRadius, y: c.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)),
                                   with: .color(white.opacity((1 - phase) * 0.55 * (1 - lit * 2))), lineWidth: 1.5)
                    }
                }

                // The near half of the halo and the sparks that drift along it; scanning speeds them up.
                if strength > 0.01 {
                    HaloArt.draw(.front, in: &ctx, center: placement.center, scale: placement.scale, opacity: strength)
                    HaloArt.drawSparkle(in: &ctx, center: placement.center, scale: placement.scale, opacity: strength, time: t * spin)
                }

                if satellite > 0.001 {
                    // The satellite lights the whole region, whatever its shape: for each piece of land of the region the beam is the hull of
                    // the satellite and of the visible outline of that piece, so it widens exactly as far as the land is wide and does not
                    // cross the sea between the pieces (Alaska, Hawaii); the land itself is the area that lights.
                    let rings = world.rings(for: region)
                    let pieces = visiblePieces(rings, view, screen, limit: 240)
                    let largest = pieces.max { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }
                    let target = largest.map { CGPoint(x: bounds($0).midX, y: bounds($0).midY) } ?? c

                    // The satellite flies in once, slows down and then stays at its station.
                    let rx = r * 1.62, ry = r * 1.32
                    let eased = 1 - pow(1 - satellite, 3)
                    let restAngle = -0.55
                    let angle = -2.7 + (restAngle + 2.7) * eased
                    var sat = CGPoint(x: c.x + rx * cos(angle), y: c.y + ry * sin(angle))
                    sat.y += sin(t * 0.9) * 1.2 * pow(eased, 4)
                    let aim = atan2(target.y - sat.y, target.x - sat.x)

                    let flicker = 0.94 + 0.06 * sin(t * 1.4)
                    ctx.drawLayer { l in
                        l.opacity = beam * flicker
                        if !pieces.isEmpty {
                            var cone = Path()
                            for piece in pieces {
                                cone.addLines(convexHull(piece + [sat]))
                                cone.closeSubpath()
                            }
                            l.fill(cone, with: .linearGradient(Gradient(colors: [white.opacity(0.03), white.opacity(0.17)]), startPoint: sat, endPoint: target))
                        }
                        // The light on the ground: the area of the country itself, over the shading of the night side, not over the edge of the disc.
                        l.drawLayer { ground in
                            ground.clip(to: Path(ellipseIn: disc))
                            ground.fill(path(rings, view, screen), with: .color(white.opacity(0.14)))
                        }
                    }

                    ctx.drawLayer { g in
                        g.opacity = min(satellite * 5, 1)
                        g.translateBy(x: sat.x, y: sat.y)
                        g.rotate(by: .radians(aim - .pi / 2 + sin(t * 0.6) * 0.04))
                        drawSatellite(&g, pulse: 0.5 + 0.5 * sin(t * 3))
                    }
                }
            }
        }
    }

    /// The outline of each piece of land of the rings that faces us, on the screen, about `limit` points in all; the pieces that
    /// are hardly seen (an island a few points wide) get no beam of their own; they light up with the region all the same.
    private func visiblePieces(_ rings: [[Double]], _ view: Orthographic, _ screen: ((x: Double, y: Double, visible: Bool)) -> CGPoint, limit: Int) -> [[CGPoint]] {
        let total = rings.reduce(0) { $0 + $1.count / 2 }
        let step = max(total / limit, 1)
        var pieces: [[CGPoint]] = []
        for ring in rings {
            var points: [CGPoint] = []
            for i in stride(from: 0, to: ring.count - 1, by: 2 * step) {
                let p = view.project(lon: ring[i], lat: ring[i + 1])
                if p.visible { points.append(screen(p)) }
            }
            if points.count > 2, max(bounds(points).width, bounds(points).height) >= 8 { pieces.append(points) }
        }
        return pieces
    }

    private func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The smallest convex polygon around the points (Andrew's monotone chain).
    private func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 2 else { return points }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    /// Where the halo sits and how large it is. The images were drawn for a ring of 80 pt; it is larger when it rests among the clouds.
    private func haloPlacement(c: CGPoint, r: CGFloat, lit: Double) -> (center: CGPoint, scale: CGFloat) {
        let crown = r * 1.22 / HaloArt.rx
        return (CGPoint(x: c.x, y: c.y - r * 0.02 - CGFloat(lit) * r * 0.91), crown * (1.55 - 0.55 * CGFloat(lit)))
    }

    private func path(_ rings: [[Double]], _ view: Orthographic, _ screen: ((x: Double, y: Double, visible: Bool)) -> CGPoint) -> Path {
        var path = Path()
        for ring in rings {
            var points: [CGPoint] = []
            var anyVisible = false
            points.reserveCapacity(ring.count / 2)
            for i in stride(from: 0, to: ring.count - 1, by: 2) {
                let p = view.project(lon: ring[i], lat: ring[i + 1])
                if p.visible { anyVisible = true }
                points.append(screen(p))
            }
            guard anyVisible, points.count > 2 else { continue }
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
        return path
    }

    private func graticule(_ view: Orthographic, _ screen: ((x: Double, y: Double, visible: Bool)) -> CGPoint) -> Path {
        var path = Path()
        func add(_ coordinates: [(Double, Double)]) {
            var drawing = false
            for (lon, lat) in coordinates {
                let p = view.project(lon: lon, lat: lat)
                if p.visible {
                    if drawing { path.addLine(to: screen(p)) } else { path.move(to: screen(p)); drawing = true }
                } else {
                    drawing = false
                }
            }
        }
        for lon in stride(from: -180.0, to: 180.0, by: 30.0) {
            add(stride(from: -90.0, through: 90.0, by: 5.0).map { (lon, $0) })
        }
        for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
            add(stride(from: -180.0, through: 180.0, by: 5.0).map { ($0, lat) })
        }
        return path
    }

    /// Body, two solar panels and a blinking antenna, around the origin, in grey.
    private func drawSatellite(_ g: inout GraphicsContext, pulse: Double) {
        SatelliteArt.draw(&g, pulse: pulse)
    }
}
