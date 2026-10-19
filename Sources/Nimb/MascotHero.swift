import SwiftUI

/// What stands under the halo on a page.
enum MascotArt: Equatable {
    /// The hooded dog of the Telegram page.
    case hood
    /// A black screen with a play button and the Discord mark: YouTube and Discord.
    case screen
    /// The graphite power button of the home page. It is the switch itself, so there is no small button below it.
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()
    @StateObject private var motion = MascotMotion()

    private var stageHeight: CGFloat { art == .power ? 236 : 208 }
    /// Where the middle of the figure is below the middle of the stage.
    private var figureY: CGFloat { art == .power ? 26 : 2 }
    private let haloSpacing: CGFloat = 24
    /// Where the crown of the figure is, relative to the middle of the stage, and how large the halo is around it.
    private var haloY: CGFloat {
        switch art {
        case .hood: -49
        case .screen: -51
        case .power: -35
        }
    }
    private var haloScale: CGFloat {
        switch art {
        case .hood: 0.80
        case .screen: 0.92
        case .power: 0.96
        }
    }
    /// What the beam of the flying thing lands on, relative to the middle of the figure: the nose, the play button.
    private var beamTarget: CGPoint {
        switch art {
        case .hood: CGPoint(x: 0, y: 33)
        case .screen: CGPoint(x: -3, y: -10)
        case .power: .zero
        }
    }

    var body: some View {
        let lit: Double = level ?? (isOn ? 1 : 0)
        let h: Double = hover.value ? 1 : 0
        let animated = lit > 0 || isBusy || motion.moving
        VStack(spacing: 6) {
            Button(action: action) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion || scenePhase != .active)) { context in
                    stage(lit: lit, hover: h, date: context.date)
                }
                .frame(width: 320, height: stageHeight)
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
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.05 + 0.13 * lit + 0.04 * hover * lit), .clear], center: .center, startRadius: 8, endRadius: 128))
                .frame(width: 270, height: 270)
                .offset(y: figureY + 2)

            haloLayer(stack, back: true, moment: moment)

            figure(lit: lit, hover: hover)
                .rotationEffect(.degrees(art == .power ? 0 : moment.sway))
                .offset(y: figureY + (art == .power ? 0 : moment.bob))

            haloLayer(stack, back: false, moment: moment)

            Canvas { ctx, size in
                drawSparks(&ctx, size: size, stack: stack, moment: moment)
                if art == .power {
                    drawRipples(&ctx, size: size, moment: moment)
                } else {
                    drawOrbiter(&ctx, size: size, progress: orbiter, moment: moment)
                }
            }
            .allowsHitTesting(false)

            if art != .power { badge(hover: hover).offset(y: 84) }
        }
    }

    private func haloLayer(_ stack: [Halo], back: Bool, moment: Moment) -> some View {
        ForEach(stack.indices, id: \.self) { i in
            let wave = haloWave(i, moment: moment)
            haloImage(back ? HaloImages.shared.back : HaloImages.shared.front, scale: stack[i].scale * wave.scale)
                .opacity(stack[i].opacity * wave.opacity * moment.busyPulse)
                // The resting place animates when a halo comes or goes; the wave of the clock is added after it, unanimated.
                .offset(y: stack[i].y)
                .animation(art == .power ? .spring(response: 0.9, dampingFraction: 0.62) : nil, value: stack[i].y)
                .offset(y: wave.y)
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
            return Halo(opacity: on ? 1 : 0, y: haloY - CGFloat(i) * haloSpacing + drop(on), scale: haloScale * (1 - 0.07 * CGFloat(i)))
        }
    }

    private func haloImage(_ image: CGImage, scale: CGFloat) -> some View {
        let size = HaloImages.shared.size
        return Image(decorative: image, scale: HaloImages.shared.pixelScale)
            .resizable()
            .frame(width: size.width * scale, height: size.height * scale)
            .allowsHitTesting(false)
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

    /// Green waves leaving the home switch while everything is on.
    private func drawRipples(_ ctx: inout GraphicsContext, size: CGSize, moment: Moment) {
        guard isOn else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2 + figureY)
        for k in 0..<2 {
            let phase = (moment.t * 0.3 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
            let r = 66 + 64 * phase
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(Theme.ok.opacity((1 - phase) * 0.35)), lineWidth: 1.2)
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

    // MARK: Figure

    /// The figure itself: dim and plain while off, with a light rim and a glow once on.
    @ViewBuilder
    private func figure(lit: Double, hover: Double) -> some View {
        let rim = 0.22 + 0.45 * lit + 0.15 * hover
        switch art {
        case .hood:
            HoodArt().lit(rim: rim, glow: lit)
        case .screen:
            ScreenArt().lit(rim: rim, glow: lit)
        case .power:
            PowerDisc(isOn: isOn, isBusy: isBusy, hover: hover)
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

private extension View {
    /// A figure under the halo: dim while off, with a thin light rim and a glow as the halo grows.
    func lit(rim: Double, glow: Double) -> some View {
        self
            .shadow(color: .white.opacity(rim * 0.8), radius: 1)
            .shadow(color: .white.opacity(0.08 + 0.16 * glow), radius: 10)
            .opacity(0.62 + 0.38 * glow)
            .scaleEffect(0.96 + 0.04 * glow)
    }
}
