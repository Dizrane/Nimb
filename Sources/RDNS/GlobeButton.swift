import SwiftUI

/// Sky view: a glass orb among the clouds. Space view: the planet with Russia lit up and a satellite
/// sending it a signal. The same button either way.
struct HeroButton: View {
    let mode: AppMode
    let space: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            if space {
                GlobeButton(mode: mode, action: action)
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

struct GlobeButton: View {
    let mode: AppMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()

    private let radius: CGFloat = 66

    var body: some View {
        Button(action: action) {
            ZStack {
                // The planet turns almost imperceptibly, so it is redrawn rarely; the signal moves fast.
                TimelineView(.animation(minimumInterval: 1.0 / 4, paused: reduceMotion || scenePhase != .active)) { context in
                    GlobeCanvas(part: .planet, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                                mode: mode, radius: radius * (hover.value ? 1.04 : 1))
                }
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || scenePhase != .active)) { context in
                    GlobeCanvas(part: .signal, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                                mode: mode, radius: radius * (hover.value ? 1.04 : 1))
                }
                powerBadge
                    .offset(y: radius * 0.56 + 8)
            }
            .frame(width: 320, height: 214)
            .contentShape(Path(ellipseIn: CGRect(x: 100, y: 34, width: 120, height: 150)))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 }
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
    let mode: AppMode
    let radius: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 8)
            let r = radius
            let accent = mode.accent
            let view = Orthographic(lon0: 74 + sin(t * 0.15) * 8, lat0: 52 + sin(t * 0.1) * 3)
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

            if part == .signal {
            // Orbit of the satellite: the upper arc, faint and dotted.
            let rx = r * 1.62, ry = r * 1.32
            var orbit = Path()
            var a = -Double.pi + 0.3
            orbit.move(to: CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)))
            while a < -0.3 {
                a += 0.05
                orbit.addLine(to: CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a)))
            }
            ctx.stroke(orbit, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6]))

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

                let russia = path(world.russia, view, screen)
                l.drawLayer { g in
                    g.addFilter(.shadow(color: accent.opacity(0.95), radius: 7))
                    g.fill(russia, with: .color(accent.opacity(0.92)))
                }
                l.stroke(russia, with: .color(.white.opacity(0.8)), lineWidth: 0.8)

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
            // Moscow: the signal lands here.
            let moscow = view.project(lon: 37.6, lat: 55.75)
            let target = moscow.visible ? screen(moscow) : c

            // Satellite sliding along the orbit.
            let u = sin(t * 0.42)
            let angle = -Double.pi / 2 + u * 0.95
            let sat = CGPoint(x: c.x + rx * cos(angle), y: c.y + ry * sin(angle))

            // Signal: a soft cone, dashes running down it and pulses.
            let dx = target.x - sat.x, dy = target.y - sat.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            let nx = -dy / length * 9, ny = dx / length * 9
            var cone = Path()
            cone.move(to: sat)
            cone.addLine(to: CGPoint(x: target.x + nx, y: target.y + ny))
            cone.addLine(to: CGPoint(x: target.x - nx, y: target.y - ny))
            cone.closeSubpath()
            ctx.fill(cone, with: .linearGradient(Gradient(colors: [accent.opacity(0.42), accent.opacity(0.06)]), startPoint: sat, endPoint: target))

            var line = Path()
            line.move(to: sat)
            line.addLine(to: target)
            ctx.stroke(line, with: .color(accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 5], dashPhase: -t * 22))
            for k in 0..<3 {
                let s = (t * 0.55 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let p = CGPoint(x: sat.x + dx * s, y: sat.y + dy * s)
                let alpha = sin(s * .pi)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white.opacity(alpha * 0.9)))
            }

            if moscow.visible {
                let ping = (t * 0.7).truncatingRemainder(dividingBy: 1)
                let pr = 3 + 13 * ping
                ctx.stroke(Path(ellipseIn: CGRect(x: target.x - pr, y: target.y - pr, width: pr * 2, height: pr * 2)),
                           with: .color(.white.opacity((1 - ping) * 0.8)), lineWidth: 1.2)
                ctx.fill(Path(ellipseIn: CGRect(x: target.x - 2.4, y: target.y - 2.4, width: 4.8, height: 4.8)), with: .color(.white))
            }

            ctx.drawLayer { g in
                g.translateBy(x: sat.x, y: sat.y)
                g.rotate(by: .radians(angle + .pi / 2))
                drawSatellite(&g, glow: accent, pulse: 0.5 + 0.5 * sin(t * 4))
            }
            }
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
