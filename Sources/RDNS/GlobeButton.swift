import SwiftUI

/// Sky view: a glass orb among the clouds. Space view: the planet with Russia lit up and a satellite
/// sending it a signal. The same button either way.
struct HeroButton: View {
    let mode: AppMode
    let space: Bool
    let region: Region
    let action: () -> Void

    var body: some View {
        ZStack {
            if space {
                GlobeButton(mode: mode, region: region, action: action)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                OrbButton(mode: mode, action: action)
                    .transition(.opacity.combined(with: .scale(scale: 1.15)))
            }
        }
        .frame(height: 214)
        .animation(.easeInOut(duration: 1.0), value: space)
    }
}

/// Where the globe is turned to; it eases towards the region of the provider that was picked.
final class GlobeRotation: ObservableObject {
    @Published private(set) var rotating = false
    private var from: (lon: Double, lat: Double)
    private var to: (lon: Double, lat: Double)
    private var started = Date.distantPast
    private let duration = 1.6
    private let born = Date()

    /// 0 when the globe appears, 1 once the satellite has settled at its station.
    func arrival(at date: Date) -> Double { min(max(date.timeIntervalSince(born) / 2.6, 0), 1) }

    init(_ region: Region) {
        from = region.view
        to = region.view
    }

    func center(at date: Date) -> (lon: Double, lat: Double) {
        let p = min(max(date.timeIntervalSince(started) / duration, 0), 1)
        let eased = p * p * (3 - 2 * p)
        var dLon = to.lon - from.lon
        while dLon > 180 { dLon -= 360 }
        while dLon < -180 { dLon += 360 }
        return (from.lon + dLon * eased, from.lat + (to.lat - from.lat) * eased)
    }

    func retarget(_ region: Region) {
        let now = Date()
        from = center(at: now)
        to = region.view
        started = now
        rotating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in self?.rotating = false }
    }
}

struct GlobeButton: View {
    let mode: AppMode
    let region: Region
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()
    @StateObject private var rotation: GlobeRotation

    private let radius: CGFloat = 66

    init(mode: AppMode, region: Region, action: @escaping () -> Void) {
        self.mode = mode
        self.region = region
        self.action = action
        _rotation = StateObject(wrappedValue: GlobeRotation(region))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The planet turns almost imperceptibly, so it is redrawn rarely, except while it swings to a new region.
                TimelineView(.animation(minimumInterval: rotation.rotating ? 1.0 / 30 : 1.0 / 4, paused: reduceMotion || scenePhase != .active)) { context in
                    GlobeCanvas(part: .planet, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                                center: rotation.center(at: context.date), region: region,
                                arrival: rotation.arrival(at: context.date), mode: mode, radius: radius * (hover.value ? 1.04 : 1))
                }
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { context in
                    GlobeCanvas(part: .signal, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                                center: rotation.center(at: context.date), region: region,
                                arrival: rotation.arrival(at: context.date), mode: mode, radius: radius * (hover.value ? 1.04 : 1))
                }
                powerBadge
                    .offset(y: radius * 0.56 + 8)
            }
            .frame(width: 320, height: 214)
            .contentShape(Path(ellipseIn: CGRect(x: 100, y: 34, width: 120, height: 150)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 }
        .onChange(of: region) { rotation.retarget($0) }
        .animation(.easeOut(duration: 0.2), value: hover.value)
    }

    private var powerBadge: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.42))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                .frame(width: 34, height: 34)
            if mode == .busy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct GlobeCanvas: View {
    enum Part { case planet, signal }

    let part: Part
    let t: Double
    let center: (lon: Double, lat: Double)
    let region: Region
    let arrival: Double
    let mode: AppMode
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 8)
            let r = radius
            let accent = mode.accent
            let view = Orthographic(lon0: center.lon + sin(t * 0.15) * 8, lat0: center.lat + sin(t * 0.1) * 3)
            let world = WorldMap.shared
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

            func screen(_ p: (x: Double, y: Double, visible: Bool)) -> CGPoint {
                CGPoint(x: c.x + CGFloat(p.x) * r, y: c.y - CGFloat(p.y) * r)
            }

            if part == .planet {
            // Atmosphere.
            ctx.fill(
                Path(ellipseIn: disc.insetBy(dx: -r * 0.6, dy: -r * 0.6)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: accent.opacity(0), location: 0),
                        .init(color: accent.opacity(0.55), location: 0.62),
                        .init(color: accent.opacity(0), location: 1),
                    ]),
                    center: c, startRadius: 0, endRadius: r * 1.6
                )
            )

            }

            // rx/ry are needed again for the satellite below.
            let rx = r * 1.62, ry = r * 1.32

            if part == .planet {
            // The planet.
            ctx.drawLayer { l in
                l.clip(to: Path(ellipseIn: disc))
                l.fill(
                    Path(disc),
                    with: .linearGradient(
                        Gradient(colors: [Color(red: 0.10, green: 0.32, blue: 0.60), Color(red: 0.02, green: 0.07, blue: 0.22)]),
                        startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)
                    )
                )
                l.stroke(graticule(view, screen), with: .color(.white.opacity(0.10)), lineWidth: 0.6)

                let land = path(world.land, view, screen)
                l.fill(land, with: .color(Color(red: 0.16, green: 0.33, blue: 0.43)))
                l.stroke(land, with: .color(.white.opacity(0.20)), lineWidth: 0.5)

                let highlighted = path(world.rings(for: region), view, screen)
                l.drawLayer { g in
                    g.addFilter(.shadow(color: accent.opacity(0.95), radius: 7))
                    g.fill(highlighted, with: .color(accent.opacity(0.92)))
                }
                l.stroke(highlighted, with: .color(.white.opacity(0.5)), lineWidth: 0.6)

                // Night side.
                l.fill(
                    Path(disc),
                    with: .linearGradient(
                        Gradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color.black.opacity(0.6), location: 1)]),
                        startPoint: CGPoint(x: disc.minX + r * 0.5, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)
                    )
                )
            }
            ctx.stroke(
                Path(ellipseIn: disc),
                with: .linearGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0.05)]),
                                      startPoint: CGPoint(x: disc.minX, y: disc.minY), endPoint: CGPoint(x: disc.maxX, y: disc.maxY)),
                lineWidth: 1.2
            )

            }

            if part == .signal {
            // The halo floats above the planet: it glows and a bright arc slowly runs around it.
            drawHalo(&ctx, center: CGPoint(x: c.x, y: c.y - r * 1.1), rx: r * 1.12, ry: r * 0.24, t: t, accent: accent)

            // The signal lands in a city of the lit-up region.
            let landing = view.project(lon: region.landing.lon, lat: region.landing.lat)
            let target = landing.visible ? screen(landing) : c

            // The satellite flies in once, slows down and then stays at its station.
            let eased = 1 - pow(1 - arrival, 3)
            let restAngle = -0.55
            let angle = -2.7 + (restAngle + 2.7) * eased
            var sat = CGPoint(x: c.x + rx * cos(angle), y: c.y + ry * sin(angle))
            sat.y += sin(t * 0.9) * 1.2 * pow(eased, 4)
            let aim = atan2(target.y - sat.y, target.x - sat.x)

            // Signal: a soft cone, dashes running down it and pulses; it switches on when the satellite is in place.
            let beam = min(max((arrival - 0.6) / 0.4, 0), 1)
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
                l.fill(cone, with: .linearGradient(Gradient(colors: [accent.opacity(0.42), accent.opacity(0.06)]), startPoint: sat, endPoint: target))

                var line = Path()
                line.move(to: sat)
                line.addLine(to: target)
                l.stroke(line, with: .color(accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 5], dashPhase: -t * 22))
                for k in 0..<3 {
                    let s = (t * 0.45 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let p = CGPoint(x: sat.x + dx * s, y: sat.y + dy * s)
                    l.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white.opacity(sin(s * .pi) * 0.9)))
                }
                if landing.visible {
                    let ping = (t * 0.7).truncatingRemainder(dividingBy: 1)
                    let pr = 3 + 13 * ping
                    l.stroke(Path(ellipseIn: CGRect(x: target.x - pr, y: target.y - pr, width: pr * 2, height: pr * 2)),
                             with: .color(.white.opacity((1 - ping) * 0.8)), lineWidth: 1.2)
                    l.fill(Path(ellipseIn: CGRect(x: target.x - 2.4, y: target.y - 2.4, width: 4.8, height: 4.8)), with: .color(.white))
                }
            }

            ctx.drawLayer { g in
                g.translateBy(x: sat.x, y: sat.y)
                g.rotate(by: .radians(aim - .pi / 2 + sin(t * 0.6) * 0.04))
                drawSatellite(&g, glow: accent, pulse: 0.5 + 0.5 * sin(t * 3))
            }
            }
        }
    }

    /// A glowing ring seen at a shallow angle. A bright arc with a fading tail runs around it, the nearer half is brighter.
    private func drawHalo(_ ctx: inout GraphicsContext, center: CGPoint, rx: CGFloat, ry: CGFloat, t: Double, accent: Color) {
        func point(_ angle: Double) -> CGPoint { CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle)) }
        var ring = Path()
        for i in 0...96 {
            let p = point(Double(i) / 96 * 2 * .pi)
            if i == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
        }
        // Two layers of bloom: a wide soft one and a tighter one.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 12))
            l.stroke(ring, with: .color(accent.opacity(0.65)), lineWidth: 12)
        }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 4))
            l.stroke(ring, with: .color(.white.opacity(0.55)), lineWidth: 4)
        }
        ctx.stroke(ring, with: .color(.white.opacity(0.62)), lineWidth: 1.6)

        let head = t * 0.4
        let steps = 36
        for k in 0..<steps {
            let a1 = head - Double(k) * 0.05, a0 = a1 - 0.05
            let fade = pow(1 - Double(k) / Double(steps), 1.6)
            let near = 0.65 + 0.35 * sin(a1)
            var segment = Path()
            segment.move(to: point(a0))
            segment.addLine(to: point(a1))
            ctx.stroke(segment, with: .color(.white.opacity(fade * near)),
                       style: StrokeStyle(lineWidth: 1.8 + 2.8 * fade * near, lineCap: .round))
        }

        let spot = point(head)
        ctx.fill(Path(ellipseIn: CGRect(x: spot.x - 22, y: spot.y - 22, width: 44, height: 44)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(0.95), accent.opacity(0.4), .clear]),
                                       center: spot, startRadius: 0, endRadius: 22))
        // Light streaks fanning out from the bright spot, like in a long exposure.
        let lengths: [CGFloat] = [16, 28, 42, 30, 18, 24, 12]
        for (i, length) in lengths.enumerated() {
            let angle = head + Double(i - 3) * 0.1
            let from = point(angle)
            let outward = CGPoint(x: cos(angle) * 0.9, y: sin(angle) * 0.45)
            var streak = Path()
            streak.move(to: from)
            streak.addLine(to: CGPoint(x: from.x + outward.x * length, y: from.y + outward.y * length))
            ctx.stroke(streak, with: .color(.white.opacity(0.4 * (1 - abs(Double(i - 3)) / 4))), lineWidth: 0.9)
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

    /// Body, two solar panels and a blinking antenna, around the origin.
    private func drawSatellite(_ g: inout GraphicsContext, glow: Color, pulse: Double) {
        let panel = Color(red: 0.12, green: 0.26, blue: 0.62)
        let edge = Color(red: 0.62, green: 0.82, blue: 1.0)
        for side in [-1.0, 1.0] {
            let x: CGFloat = side < 0 ? -23 : 8
            let rect = CGRect(x: x, y: -4, width: 15, height: 8)
            g.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(panel))
            var grid = Path()
            for i in 1..<4 {
                grid.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.minY))
                grid.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.maxY))
            }
            grid.move(to: CGPoint(x: rect.minX, y: 0)); grid.addLine(to: CGPoint(x: rect.maxX, y: 0))
            g.stroke(grid, with: .color(edge.opacity(0.45)), lineWidth: 0.5)
            g.stroke(Path(roundedRect: rect, cornerRadius: 1), with: .color(edge.opacity(0.85)), lineWidth: 0.7)
        }
        var struts = Path()
        struts.move(to: CGPoint(x: -8, y: 0)); struts.addLine(to: CGPoint(x: -5, y: 0))
        struts.move(to: CGPoint(x: 5, y: 0)); struts.addLine(to: CGPoint(x: 8, y: 0))
        g.stroke(struts, with: .color(.white.opacity(0.8)), lineWidth: 1)

        let body = Path(roundedRect: CGRect(x: -5, y: -5, width: 10, height: 10), cornerRadius: 2.2)
        g.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.96), Color(white: 0.68)]),
                                           startPoint: CGPoint(x: -5, y: -5), endPoint: CGPoint(x: 5, y: 5)))
        g.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 0.6)

        g.fill(Path(ellipseIn: CGRect(x: -9, y: 1, width: 18, height: 18)),
               with: .radialGradient(Gradient(colors: [glow.opacity(0.65 * pulse + 0.2), glow.opacity(0)]),
                                     center: CGPoint(x: 0, y: 10), startRadius: 0, endRadius: 9))
        g.fill(Path(ellipseIn: CGRect(x: -1.8, y: 8.2, width: 3.6, height: 3.6)), with: .color(.white))
        var dish = Path()
        dish.move(to: CGPoint(x: 0, y: 5)); dish.addLine(to: CGPoint(x: 0, y: 8.5))
        g.stroke(dish, with: .color(.white.opacity(0.9)), lineWidth: 1)
    }
}
