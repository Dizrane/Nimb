import SwiftUI

/// The main button. Off: one large, bright button among the clouds. On: the planet with a glowing halo over it,
/// the region of the chosen provider lit up in green and a satellite sending it a signal.
struct HeroButton: View {
    let mode: AppMode
    let lit: Bool
    let region: Region
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
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
        Button(action: action) {
            ZStack {
                // The planet changes slowly, so it is redrawn rarely, except while something is moving.
                TimelineView(.animation(minimumInterval: state.moving ? 1.0 / 30 : 1.0 / 4, paused: reduceMotion || scenePhase != .active)) { context in
                    canvas(.planet, context.date)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { context in
                    canvas(.signal, context.date)
                }
                bigButton
                    .opacity(lit ? 0 : 1)
                    .scaleEffect(lit ? 0.5 : 1)
                    .offset(y: 8)
                    .animation(.easeInOut(duration: 0.9), value: lit)
                badge
                    .opacity(lit ? 1 : 0)
                    .scaleEffect(lit ? 1 : 0.5)
                    .offset(y: radius * 0.56 + 8)
                    .animation(.easeInOut(duration: 1.2).delay(lit ? 0.5 : 0), value: lit)
            }
            .frame(width: 320, height: 214)
            .contentShape(Path(ellipseIn: CGRect(x: 70, y: 34, width: 180, height: 150)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 }
        .onChange(of: region) { state.retarget($0) }
        .onChange(of: lit) { state.setLit($0) }
        .animation(.easeOut(duration: 0.2), value: hover.value)
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
            radius: radius * (hover.value ? 1.04 : 1)
        )
    }

    /// The button while DNS is off: large and bright, so that it is plainly the thing to press.
    private var bigButton: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .shadow(color: .white.opacity(hover.value ? 0.6 : 0.38), radius: hover.value ? 28 : 20)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
            if mode == .busy {
                ProgressView().controlSize(.regular).tint(.black)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Color(white: 0.08))
            }
        }
        .frame(width: 124, height: 124)
        .scaleEffect(hover.value ? 1.04 : 1)
    }

    /// The small button under the planet while DNS is on.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .overlay(Circle().strokeBorder(Theme.ok.opacity(0.85), lineWidth: 1.3))
                .frame(width: 40, height: 40)
            if mode == .busy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ok)
            }
        }
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
        litStarted = now
        satelliteStarted = now
        keepMoving(for: on ? 0.25 + satelliteInTime + 0.2 : litDuration + 0.2)
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
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 8)
            let r = radius * (0.88 + 0.12 * lit)
            let view = Orthographic(lon0: center.lon + sin(t * 0.15) * 8, lat0: center.lat + sin(t * 0.1) * 3)
            let world = WorldMap.shared
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let white = Color.white
            let green = Theme.ok

            // The halo: resting in the middle among the clouds while off, crowning the planet while on.
            let spin: Double = mode == .probing ? 3.0 : mode == .busy ? 2.0 : 1.0
            let pulse = mode == .busy ? 0.75 + 0.25 * sin(t * 5) : 1
            let strength = lit * pulse
            let placement = haloPlacement(c: c, r: r, lit: lit)

            func screen(_ p: (x: Double, y: Double, visible: Bool)) -> CGPoint {
                CGPoint(x: c.x + CGFloat(p.x) * r, y: c.y - CGFloat(p.y) * r)
            }

            if part == .planet {
                if strength > 0.01 { drawHaloImage(&ctx, HaloImages.shared.back, placement, opacity: strength) }
                ctx.drawLayer { ctx in
                ctx.opacity = lit
                // Faint atmosphere, stronger when lit.
                ctx.fill(
                    Path(ellipseIn: disc.insetBy(dx: -r * 0.6, dy: -r * 0.6)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: white.opacity(0), location: 0),
                            .init(color: white.opacity(0.05 + 0.22 * lit), location: 0.62),
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
                    l.stroke(graticule(view, screen), with: .color(white.opacity(0.07 + 0.05 * lit)), lineWidth: 0.6)

                    let land = path(world.land, view, screen)
                    l.fill(land, with: .color(white.opacity(0.10 + 0.08 * lit)))
                    l.stroke(land, with: .color(white.opacity(0.22 + 0.12 * lit)), lineWidth: 0.5)

                    // The region of the chosen provider: a faint outline before connecting, solid white after.
                    let highlighted = path(world.rings(for: region), view, screen)
                    l.drawLayer { g in
                        g.addFilter(.shadow(color: green.opacity(0.9 * lit), radius: 7))
                        g.fill(highlighted, with: .color(green.opacity(0.14 + 0.78 * lit)))
                    }
                    l.stroke(highlighted, with: .color(.white.opacity(0.35 + 0.25 * lit)), lineWidth: 0.7)

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
                    with: .linearGradient(Gradient(colors: [white.opacity(0.35 + 0.4 * lit), white.opacity(0.04)]),
                                          startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)),
                    lineWidth: 1.2
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
                    drawHaloImage(&ctx, HaloImages.shared.front, placement, opacity: strength)
                    drawSparks(&ctx, placement, t: t, spin: spin, strength: strength)
                }

                if satellite > 0.001 {
                    // The signal lands in a city of the lit-up region.
                    let landing = view.project(lon: region.landing.lon, lat: region.landing.lat)
                    let target = landing.visible ? screen(landing) : c

                    // The satellite flies in once, slows down and then stays at its station.
                    let rx = r * 1.62, ry = r * 1.32
                    let eased = 1 - pow(1 - satellite, 3)
                    let restAngle = -0.55
                    let angle = -2.7 + (restAngle + 2.7) * eased
                    var sat = CGPoint(x: c.x + rx * cos(angle), y: c.y + ry * sin(angle))
                    sat.y += sin(t * 0.9) * 1.2 * pow(eased, 4)
                    let aim = atan2(target.y - sat.y, target.x - sat.x)

                    let beam = min(max((satellite - 0.6) / 0.4, 0), 1)
                    let dx = target.x - sat.x, dy = target.y - sat.y
                    let length = max((dx * dx + dy * dy).squareRoot(), 1)
                    let nx = -dy / length * 9, ny = dx / length * 9
                    ctx.drawLayer { l in
                        l.opacity = beam
                        var cone = Path()
                        cone.move(to: sat)
                        cone.addLine(to: CGPoint(x: target.x + nx, y: target.y + ny))
                        cone.addLine(to: CGPoint(x: target.x - nx, y: target.y - ny))
                        cone.closeSubpath()
                        l.fill(cone, with: .linearGradient(Gradient(colors: [green.opacity(0.45), green.opacity(0.05)]), startPoint: sat, endPoint: target))

                        var line = Path()
                        line.move(to: sat)
                        line.addLine(to: target)
                        l.stroke(line, with: .color(green.opacity(0.95)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [2, 5], dashPhase: -t * 22))
                        for k in 0..<3 {
                            let s = (t * 0.45 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                            let p = CGPoint(x: sat.x + dx * s, y: sat.y + dy * s)
                            l.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(white.opacity(sin(s * .pi) * 0.9)))
                        }
                        if landing.visible {
                            let ping = (t * 0.7).truncatingRemainder(dividingBy: 1)
                            let pr = 3 + 13 * ping
                            l.stroke(Path(ellipseIn: CGRect(x: target.x - pr, y: target.y - pr, width: pr * 2, height: pr * 2)),
                                     with: .color(white.opacity((1 - ping) * 0.8)), lineWidth: 1.2)
                            l.fill(Path(ellipseIn: CGRect(x: target.x - 2.4, y: target.y - 2.4, width: 4.8, height: 4.8)), with: .color(white))
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

    /// Where the halo sits and how large it is. The images were drawn for a ring of 80 pt; it is larger when it rests among the clouds.
    private func haloPlacement(c: CGPoint, r: CGFloat, lit: Double) -> (center: CGPoint, scale: CGFloat) {
        let crown = r * 1.22 / HaloImages.shared.rx
        return (CGPoint(x: c.x, y: c.y - r * 0.02 - CGFloat(lit) * r * 0.91), crown * (1.55 - 0.55 * CGFloat(lit)))
    }

    private func drawHaloImage(_ ctx: inout GraphicsContext, _ image: CGImage, _ place: (center: CGPoint, scale: CGFloat), opacity: Double) {
        let size = HaloImages.shared.size
        let rect = CGRect(x: place.center.x - size.width * place.scale / 2, y: place.center.y - size.height * place.scale / 2,
                          width: size.width * place.scale, height: size.height * place.scale)
        ctx.drawLayer { l in
            l.opacity = opacity
            l.draw(Image(decorative: image, scale: HaloImages.shared.pixelScale), in: rect)
        }
    }

    /// Sparks and thin arcs drifting along the near half of the ring. The band itself stays evenly lit.
    private func drawSparks(_ ctx: inout GraphicsContext, _ place: (center: CGPoint, scale: CGFloat), t: Double, spin: Double, strength: Double) {
        let rx = HaloImages.shared.rx * place.scale, ry = HaloImages.shared.ry * place.scale
        func point(_ angle: Double, _ scale: Double) -> CGPoint {
            CGPoint(x: place.center.x + rx * scale * cos(angle), y: place.center.y - ry * scale * sin(angle))
        }
        /// 1 on the near half, fading to 0 at the horizon where the ring turns away.
        func visibility(_ angle: Double) -> Double {
            let v = min(max((sin(angle) + 0.15) / 0.35, 0), 1)
            return v * v * (3 - 2 * v)
        }

        for spark in HaloSparks.sparks {
            let angle = spark.base - t * spark.speed * spin
            let seen = visibility(angle)
            guard seen > 0.01 else { continue }
            let p = point(angle, 1 + spark.offset)
            let tangent = CGPoint(x: rx * sin(angle), y: ry * cos(angle))
            let length = max((tangent.x * tangent.x + tangent.y * tangent.y).squareRoot(), 1)
            let alpha = spark.alpha * seen * strength * (0.55 + 0.45 * sin(t * 1.4 + spark.phase))
            var line = Path()
            line.move(to: p)
            line.addLine(to: CGPoint(x: p.x + tangent.x / length * spark.length * place.scale, y: p.y + tangent.y / length * spark.length * place.scale))
            ctx.stroke(line, with: .color(.white.opacity(alpha)), lineWidth: spark.width)
        }

        for arc in HaloSparks.arcs {
            let start = arc.base - t * arc.speed * spin
            let seen = visibility(start + arc.span / 2)
            guard seen > 0.01 else { continue }
            var path = Path()
            for i in 0...8 {
                let p = point(start + arc.span * Double(i) / 8, arc.scale)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.white.opacity(arc.alpha * seen * strength)), lineWidth: arc.width)
        }
    }

    /// Rings of lon/lat degrees to a path. A ring is only drawn if part of it faces us; hidden vertices sit on the rim.
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
        for side in [-1.0, 1.0] {
            let x: CGFloat = side < 0 ? -23 : 8
            let rect = CGRect(x: x, y: -4, width: 15, height: 8)
            g.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color(white: 0.1)))
            var grid = Path()
            for i in 1..<4 {
                grid.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.minY))
                grid.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.maxY))
            }
            grid.move(to: CGPoint(x: rect.minX, y: 0)); grid.addLine(to: CGPoint(x: rect.maxX, y: 0))
            g.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            g.stroke(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)), lineWidth: 0.7)
        }
        var struts = Path()
        struts.move(to: CGPoint(x: -8, y: 0)); struts.addLine(to: CGPoint(x: -5, y: 0))
        struts.move(to: CGPoint(x: 5, y: 0)); struts.addLine(to: CGPoint(x: 8, y: 0))
        g.stroke(struts, with: .color(.white.opacity(0.8)), lineWidth: 1)

        let body = Path(roundedRect: CGRect(x: -5, y: -5, width: 10, height: 10), cornerRadius: 2.2)
        g.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.6)]),
                                           startPoint: CGPoint(x: -5, y: -5), endPoint: CGPoint(x: 5, y: 5)))
        g.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 0.6)

        g.fill(Path(ellipseIn: CGRect(x: -9, y: 1, width: 18, height: 18)),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.6 * pulse + 0.2), .white.opacity(0)]),
                                     center: CGPoint(x: 0, y: 10), startRadius: 0, endRadius: 9))
        g.fill(Path(ellipseIn: CGRect(x: -1.8, y: 8.2, width: 3.6, height: 3.6)), with: .color(.white))
        var dish = Path()
        dish.move(to: CGPoint(x: 0, y: 5)); dish.addLine(to: CGPoint(x: 0, y: 8.5))
        g.stroke(dish, with: .color(.white.opacity(0.9)), lineWidth: 1)
    }
}

/// The sparks and thin arcs that drift along the halo, fixed once so they look the same on every launch.
private enum HaloSparks {
    struct Spark { let base, speed, offset, length, alpha, phase, width: Double }
    struct Arc { let base, span, scale, speed, alpha, width: Double }

    private static var generator: UInt64 = 33
    private static func next() -> Double {
        generator = generator &* 6364136223846793005 &+ 1442695040888963407
        return Double(generator >> 33) / Double(1 << 31)
    }
    private static func random(_ low: Double, _ high: Double) -> Double { low + next() * (high - low) }

    static let sparks: [Spark] = (0..<64).map { _ in
        Spark(base: random(0, 2 * .pi), speed: random(0.05, 0.16), offset: random(0, 0.07), length: random(1.5, 11),
              alpha: random(0.25, 0.85), phase: random(0, 6.28), width: random(0.5, 1.3))
    }

    static let arcs: [Arc] = (0..<10).map { _ in
        Arc(base: random(0, 2 * .pi), span: random(0.35, 1.1), scale: random(0.9, 0.99), speed: random(0.04, 0.1),
            alpha: random(0.15, 0.4), width: random(0.5, 1.1))
    }
}
