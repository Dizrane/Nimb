import SwiftUI

/// What stands under the halo on a page.
enum MascotArt: Equatable {
    /// The hooded dog of the Telegram page.
    case hood
    /// A black screen with a play button and the Discord mark: YouTube and Discord.
    case screen
    /// Nothing but the halos: the home page, a tower of them, one for each service that is on.
    case power
}

/// The big switch of the Telegram, YouTube/Discord and home pages, made like the one of the DNS page: a figure under the
/// halo of Nimb. The halo comes down and the figure lights up when the service is on; a small flying thing (the satellite,
/// a paper plane) comes in and sends a beam to the figure; a small power button sits below.
struct MascotHero: View {
    let art: MascotArt
    let isOn: Bool
    let isBusy: Bool
    /// How much of the halo shines, 0 to 1. By default all of it while on, none while off; the home page uses the
    /// part of the services that are on.
    var level: Double? = nil
    /// The home page stacks one halo for each service that is on (up to three). Nil: one halo that fades in and out.
    var halos: Int? = nil
    let title: String
    let subtitle: String
    let accessibility: String
    var disabled = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var gate = AnimationGate.shared
    @StateObject private var hover = Flag()
    @StateObject private var motion = MascotMotion()

    private let stageHeight: CGFloat = 218
    /// Where the middle of the figure (on the home page, of the tower of halos) is below the middle of the stage.
    private var figureY: CGFloat { art == .power ? -8 : 2 }
    private let haloSpacing: CGFloat = 24
    /// Where the crown of the figure is, relative to the middle of the stage, and how large the halo is around it.
    private var haloY: CGFloat {
        switch art {
        case .hood: -49
        case .screen: -36
        case .power: 18
        }
    }
    private var haloScale: CGFloat {
        switch art {
        case .hood: 0.80
        case .screen: 0.80
        case .power: 0.96
        }
    }
    /// What the beam of the flying thing lands on, relative to the middle of the figure: the nose, the play button.
    private var beamTarget: CGPoint {
        switch art {
        case .hood: CGPoint(x: 0, y: 33)
        case .screen: CGPoint(x: -2, y: -8)
        case .power: .zero
        }
    }

    var body: some View {
        let lit: Double = level ?? (isOn ? 1 : 0)
        let h: Double = hover.value ? 1 : 0
        let animated = lit > 0 || isBusy || motion.moving
        VStack(spacing: 6) {
            Button(action: action) {
                // Slow breathing needs few frames; the flight of the plane or the satellite gets more of them.
                ZStack {
                    TimelineView(.animation(minimumInterval: motion.moving ? 1.0 / 30 : 1.0 / 12, paused: !animated || reduceMotion || !gate.shouldRun(brief: motion.moving))) { context in
                        stage(lit: lit, hover: h, date: context.date)
                    }
                    badge(hover: h).offset(y: 90)
                }
                .frame(width: 360, height: stageHeight)
                // The glow fades out before the edges of the stage, so that it never reaches the tab bar or the title.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.10),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)
            .onHover { hover.value = $0 }
            .animation(.easeInOut(duration: 1.0), value: lit)
            .animation(.easeInOut(duration: 0.4), value: hover.value)
            .accessibilityLabel(accessibility)
            .onAppear { if isOn { motion.set(on: true) } }
            .onChange(of: isOn) { motion.set(on: $0) }

            Text(title)
                .font(Typo.status)
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                .contentTransition(.opacity)

            Text(subtitle)
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, minHeight: 38, alignment: .top)
        }
        .padding(.top, -6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.35), value: title)
    }

    // MARK: Stage

    /// One halo as it is drawn: how much it shines, where it rests and how large it is. The movement of the moment comes on top.
    private struct Halo {
        var opacity: Double
        var y: CGFloat
        var scale: CGFloat
    }

    /// The moving parts at a moment: they are not animated by SwiftUI, they are drawn from the clock.
    private struct Moment {
        let t: Double
        let bob: CGFloat
        let sway: Double
        let busyPulse: Double

        init(date: Date, on: Bool, busy: Bool, still: Bool) {
            t = still ? 0 : date.timeIntervalSinceReferenceDate
            bob = on && !still ? CGFloat(sin(t * 0.9) * 2.2) : 0
            sway = on && !still ? sin(t * 0.6) * 0.9 : 0
            busyPulse = busy && !still ? 0.75 + 0.25 * sin(t * 5) : 1
        }
    }

    private func stage(lit: Double, hover: Double, date: Date) -> some View {
        let moment = Moment(date: date, on: lit > 0, busy: isBusy, still: reduceMotion)
        let stack = haloStack(lit: lit)
        let orbiter = reduceMotion ? (isOn ? 1.0 : 0.0) : motion.orbiter(at: date)
        let pictures = MascotImages.shared.pictures(for: art)
        // One canvas draws everything that moves, bitmap by bitmap; SwiftUI does not lay out a view tree on every frame.
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + figureY)

            // The soft light behind the figure.
            let glow = 0.05 + 0.13 * lit + 0.04 * hover * lit
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 135, y: c.y + 2 - 135, width: 270, height: 270)),
                     with: .radialGradient(Gradient(colors: [Color.white.opacity(glow), .clear]), center: CGPoint(x: c.x, y: c.y + 2), startRadius: 8, endRadius: 128))

            drawHalos(&ctx, size: size, stack: stack, moment: moment, back: true)

            if let pictures {
                // Off and on are two bitmaps that cross-fade; the figure floats and sways a little while it is on.
                ctx.drawLayer { layer in
                    layer.translateBy(x: c.x, y: c.y + moment.bob)
                    layer.rotate(by: .degrees(moment.sway))
                    draw(pictures.off, in: &layer, opacity: 1 - lit)
                    draw(pictures.on, in: &layer, opacity: lit)
                }
            }

            drawHalos(&ctx, size: size, stack: stack, moment: moment, back: false)
            drawSparks(&ctx, size: size, stack: stack, moment: moment)
            if art != .power { drawOrbiter(&ctx, size: size, progress: orbiter, moment: moment) }
        }
    }

    /// A bitmap centred on the origin of the context.
    private func draw(_ picture: MascotImages.Picture, in ctx: inout GraphicsContext, opacity: Double) {
        guard opacity > 0.003 else { return }
        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.draw(Image(decorative: picture.image, scale: 2), in: CGRect(x: -picture.size.width / 2, y: -picture.size.height / 2, width: picture.size.width, height: picture.size.height))
        }
    }

    /// The halos of the stack: the back half before the figure, the front half after it.
    private func drawHalos(_ ctx: inout GraphicsContext, size: CGSize, stack: [Halo], moment: Moment, back: Bool) {
        let images = HaloImages.shared
        let image = Image(decorative: back ? images.back : images.front, scale: images.pixelScale)
        for (i, halo) in stack.enumerated() where halo.opacity > 0.003 {
            let wave = haloWave(i, moment: moment)
            let scale = halo.scale * wave.scale
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + halo.y + wave.y)
            let rect = CGRect(x: center.x - images.size.width * scale / 2, y: center.y - images.size.height * scale / 2,
                              width: images.size.width * scale, height: images.size.height * scale)
            ctx.drawLayer { layer in
                layer.opacity = halo.opacity * wave.opacity * moment.busyPulse
                layer.draw(image, in: rect)
            }
        }
    }

    /// The breathing of a halo. On the home page the halos move in a wave, each a moment after the one below it.
    private func haloWave(_ index: Int, moment: Moment) -> (y: CGFloat, opacity: Double, scale: CGFloat) {
        let t = moment.t
        if art == .power {
            let phase = Double(index)
            return (CGFloat(sin(t * 1.5 - phase * 0.8) * 2.6), 0.9 + 0.1 * sin(t * 2.0 - phase * 1.1), 1 + 0.015 * CGFloat(sin(t * 1.5 - phase * 0.8)))
        }
        return (moment.bob * 0.7, 0.93 + 0.07 * sin(t * 1.7), 1 + 0.012 * CGFloat(sin(t * 1.3)))
    }

    /// The halos to draw: one that fades in over the figure, or on the home page one for every service that is on,
    /// each a little smaller and higher than the one below it.
    private func haloStack(lit: Double) -> [Halo] {
        // Without Reduce Motion a halo comes down from above as it appears.
        let drop: (Bool) -> CGFloat = { on in on || reduceMotion ? 0 : -18 }
        guard let halos else {
            return [Halo(opacity: lit, y: haloY + (reduceMotion ? 0 : CGFloat(lit - 1) * 18), scale: haloScale)]
        }
        return (0..<3).map { i in
            let on = i < halos
            // With nothing on, the lowest halo rests, faint, so that the page is not empty.
            let resting = halos == 0 && i == 0
            return Halo(opacity: on ? 1 : (resting ? 0.22 : 0), y: haloY - CGFloat(i) * haloSpacing + drop(on || resting), scale: haloScale * (1 - 0.07 * CGFloat(i)))
        }
    }

    // MARK: Canvas

    /// Sparks run around every halo that is on; neighbouring halos turn in opposite directions.
    private func drawSparks(_ ctx: inout GraphicsContext, size: CGSize, stack: [Halo], moment: Moment) {
        for (i, halo) in stack.enumerated() where halo.opacity > 0.01 {
            let wave = haloWave(i, moment: moment)
            let direction: Double = i % 2 == 0 ? 1 : -1
            let place = (center: CGPoint(x: size.width / 2, y: size.height / 2 + halo.y + wave.y), scale: halo.scale * wave.scale)
            HaloSparks.draw(&ctx, place, t: moment.t + Double(i) * 3.1, spin: direction * (isBusy ? 2 : 1),
                            strength: halo.opacity * wave.opacity * moment.busyPulse)
        }
    }

    /// The flying thing: comes in on an arc after the figure is lit, stops at its station and sends a dashed beam to the figure.
    private func drawOrbiter(_ ctx: inout GraphicsContext, size: CGSize, progress p: Double, moment: Moment) {
        guard p > 0.001 else { return }
        let t = moment.t
        let c = CGPoint(x: size.width / 2, y: size.height / 2 + figureY)
        let target = CGPoint(x: c.x + beamTarget.x, y: c.y + beamTarget.y + moment.bob)
        let eased = 1 - pow(1 - p, 3)
        let angle = -2.7 + (-0.55 + 2.7) * eased
        var spot = CGPoint(x: c.x + 112 * cos(angle), y: c.y + 78 * sin(angle))
        spot.y += sin(t * 0.9) * 1.2 * pow(eased, 4)
        let aim = atan2(target.y - spot.y, target.x - spot.x)

        let beam = min(max((p - 0.6) / 0.4, 0), 1)
        let dx = target.x - spot.x, dy = target.y - spot.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / length * 8, ny = dx / length * 8
        ctx.drawLayer { l in
            l.opacity = beam
            var cone = Path()
            cone.move(to: spot)
            cone.addLine(to: CGPoint(x: target.x + nx, y: target.y + ny))
            cone.addLine(to: CGPoint(x: target.x - nx, y: target.y - ny))
            cone.closeSubpath()
            l.fill(cone, with: .linearGradient(Gradient(colors: [Theme.ok.opacity(0.28), Theme.ok.opacity(0.02)]), startPoint: spot, endPoint: target))
            var line = Path()
            line.move(to: spot)
            line.addLine(to: target)
            l.stroke(line, with: .color(Theme.ok.opacity(0.8)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, dash: [1.5, 4], dashPhase: -t * 8))
            let ping = (t * 0.33).truncatingRemainder(dividingBy: 1)
            let pr = 2.5 + 11 * ping
            l.stroke(Path(ellipseIn: CGRect(x: target.x - pr, y: target.y - pr, width: pr * 2, height: pr * 2)),
                     with: .color(.white.opacity((1 - ping) * 0.6)), lineWidth: 0.9)
            l.fill(Path(ellipseIn: CGRect(x: target.x - 1.8, y: target.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white))
        }
        ctx.drawLayer { g in
            g.opacity = min(p * 5, 1)
            g.translateBy(x: spot.x, y: spot.y)
            g.rotate(by: .radians(aim - .pi / 2 + sin(t * 0.6) * 0.04))
            if art == .hood {
                PaperPlaneArt.draw(&g, pulse: 0.5 + 0.5 * sin(t * 3))
            } else {
                SatelliteArt.draw(&g, pulse: 0.5 + 0.5 * sin(t * 3))
            }
        }
    }

    /// The small power button under the figure, the same as the one under the planet.
    private func badge(hover: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .overlay(Circle().strokeBorder((isOn ? Theme.ok : Color.white).opacity(isOn ? 0.7 : 0.30 + 0.25 * hover), lineWidth: 1))
                .frame(width: 40, height: 40)
            if isBusy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isOn ? Theme.ok : Color.white.opacity(0.85))
            }
        }
    }
}
