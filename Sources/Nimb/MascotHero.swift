import SwiftUI

/// What stands under the halo on a page.
enum MascotArt: Equatable {
    /// The hooded dog of the Telegram page, with a paper plane that wanders around it.
    case hood
    /// A black screen with a play button and the Discord mark: YouTube and Discord. Sound arcs, a glint and a blink say it works.
    case screen
    /// Nothing but the halos: the home page, a tower of them, one for each service that is on.
    case power
}

/// The big switch of the home, Telegram and YouTube/Discord pages: a figure under the halo of Nimb. The halo comes down and
/// the figure lights up when the service is on, a small power button sits below. Every picture comes from the art studio
/// (`Art/halo`, `Art/hood`, `Art/media-scene`, `Art/paper-plane`) and everything moving is drawn by one canvas from a clock.
struct MascotHero: View {
    let art: MascotArt
    let isOn: Bool
    let isBusy: Bool
    /// The home page stacks one halo for each service that is on (up to three).
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

    private let stageHeight = HeroLayout.stageHeight

    var body: some View {
        let h: Double = hover.value ? 1 : 0
        // A timeline that is paused keeps the picture of the moment it stopped, which may be one from the middle of a switch (or from
        // before it): then the figure shows the opposite of the title. A paused page is therefore drawn from the time of now, every
        // time something changes, and the clock that keeps the redraw going (`motion.moving`) ends with a change too.
        let running = animated && !(reduceMotion && !motion.moving) && gate.shouldRun(brief: motion.moving)
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    TimelineView(.animation(minimumInterval: motion.moving ? 1.0 / 30 : 1.0 / 20, paused: !running)) { context in
                        stage(hover: h, date: running ? context.date : Date())
                    }
                    .frame(width: 360, height: stageHeight)
                    // The glow fades out before the edges of the stage, so that it never reaches the tab bar or the title.
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.10),
                                                 .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    PowerButton(progress: isOn ? 1 : 0, hover: h, busy: isBusy, restY: PowerButton.restY, settledY: PowerButton.settledY)
                        .powerButtonAnimation(on: isOn, hovering: hover.value)
                }
                .frame(width: 360, height: stageHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)
            .onHover { hover.value = $0 }
            .animation(.easeInOut(duration: 0.4), value: hover.value)
            .accessibilityLabel(accessibility)
            .onAppear { sync(initial: true) }
            // The new value is taken from the change itself: the closure may be the one of an earlier pass, and reading `isOn` there
            // would give the value from before the switch, so the figure would stay as it was.
            .onChange(of: isOn) { on in if halos == nil { motion.set(on: on) } }
            .onChange(of: halos) { count in if let count { motion.set(rings: count) } }

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
                .frame(maxWidth: 320, minHeight: HeroLayout.subtitleHeight, alignment: .top)
        }
        .padding(.top, -6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.35), value: title)
    }

    private var animated: Bool { isOn || (halos ?? 0) > 0 || isBusy || motion.moving }

    private func sync(initial: Bool) {
        if let halos { motion.set(rings: halos) } else { motion.set(on: isOn) }
    }

    // MARK: Geometry

    /// Where the ring of the halo is relative to the middle of the stage, and how large the halo is (`art-studio/deliver/*/manifest.json`).
    private var haloCenterY: CGFloat { art == .hood ? -61 : -61 }
    private var haloScale: CGFloat { 0.8 }
    private let figureY: CGFloat = 2

    // MARK: Stage

    /// The things of one frame that depend on the clock.
    private struct Frame {
        let date: Date
        let t: Double
        let size: CGSize
        let hover: Double
        /// The pulse of a service that is switching.
        let pulse: Double
        let sparkleSpeed: Double
        var middle: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    }

    private func stage(hover: Double, date: Date) -> some View {
        let still = reduceMotion
        let t = still ? 0 : date.timeIntervalSinceReferenceDate
        let pulse = isBusy && !still ? 0.75 + 0.25 * sin(t * 5) : 1
        if art == .hood && !still { motion.advance(to: date, speed: isBusy ? 1.5 : 1.0) }
        return Canvas { ctx, size in
            let frame = Frame(date: date, t: t, size: size, hover: hover, pulse: pulse, sparkleSpeed: isBusy ? 2 : 1)
            draw(&ctx, frame)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, _ f: Frame) {
        let lit = motion.lit(at: f.date)
        let bob = lit > 0 && !reduceMotion && art != .power ? CGFloat(sin(f.t * 0.9) * 2.2) * CGFloat(lit) : 0
        let sway = lit > 0 && !reduceMotion && art == .hood ? sin(f.t * 0.6) * 0.9 * lit : 0
        let figure = CGPoint(x: f.middle.x, y: f.middle.y + figureY + bob)

        // The soft light behind the figure.
        let glow = 0.05 + 0.13 * lit + 0.04 * f.hover * lit
        let glowCenter = CGPoint(x: f.middle.x, y: f.middle.y + (art == .power ? 0 : figureY + 2))
        ctx.fill(Path(ellipseIn: CGRect(x: glowCenter.x - 135, y: glowCenter.y - 135, width: 270, height: 270)),
                 with: .radialGradient(Gradient(colors: [Color.white.opacity(glow), .clear]), center: glowCenter, startRadius: 8, endRadius: 128))

        let halos = haloList(f, lit: lit, bob: bob)
        let planeOpacity = art == .hood && !reduceMotion ? motion.appear(at: f.date, delay: 0.4, duration: 1.8) : 0

        drawPlane(&ctx, f, figure: figure, band: 0, opacity: planeOpacity)
        for halo in halos { drawBack(&ctx, halo) }
        drawPlane(&ctx, f, figure: figure, band: 1, opacity: planeOpacity)

        drawFigure(&ctx, figure: figure, lit: lit, sway: sway)
        if art == .screen && !reduceMotion {
            let appear = motion.appear(at: f.date, delay: 0.5, duration: 1.5)
            MediaMotion.draw(in: &ctx, origin: CGPoint(x: figure.x - 80, y: figure.y - 66), t: f.t * (isBusy ? 1.6 : 1), lit: appear)
        }

        drawPlane(&ctx, f, figure: figure, band: 2, opacity: planeOpacity)
        for halo in halos { drawFront(&ctx, halo, f) }
        drawPlane(&ctx, f, figure: figure, band: 3, opacity: planeOpacity)
    }

    // MARK: Halos

    private struct HaloSpec {
        var center: CGPoint
        var scale: CGFloat
        var opacity: Double
        /// The loop of sparkles of each halo of a stack is shifted in time.
        var shift: Double
    }

    /// The halos to draw this frame: one on the pages of a figure, a stack on the home page.
    private func haloList(_ f: Frame, lit: Double, bob: CGFloat) -> [HaloSpec] {
        let t = f.t
        func breathe(_ phase: Double) -> (opacity: Double, scale: CGFloat) {
            reduceMotion ? (1, 1) : ((0.93 + 0.07 * sin(1.7 * t - phase)) * f.pulse, 1 + 0.012 * CGFloat(sin(1.3 * t - phase)))
        }
        guard halos != nil else {
            let b = breathe(0)
            let drop = reduceMotion ? 0 : CGFloat(lit - 1) * 18
            let center = CGPoint(x: f.middle.x, y: f.middle.y + haloCenterY + drop + bob * 0.7)
            return [HaloSpec(center: center, scale: haloScale * b.scale, opacity: lit * b.opacity, shift: 0)]
        }
        // The stack of the home page, the lowest ring first; all the rings are the same.
        let values = (0..<3).map { motion.ring($0, at: f.date) }
        let multiplier = [0.80, 0.92, 1.0]
        return (0..<3).map { i in
            let b = breathe(0.8 * Double(i))
            var value = values[i]
            if i == 0 { value = max(value, 0.22 * (1 - lit)) }
            let drop = reduceMotion ? 0 : CGFloat(values[i] - 1) * 18
            let wave = reduceMotion ? 0 : CGFloat(sin(1.5 * t - 0.8 * Double(i)) * 1.6)
            return HaloSpec(center: CGPoint(x: f.middle.x, y: f.middle.y + 22 - 28 * CGFloat(i) + drop + wave),
                            scale: 0.96 * (1 - 0.07 * CGFloat(i)) * b.scale,
                            opacity: value * multiplier[i] * b.opacity,
                            shift: Double(i) * 0.37)
        }
    }

    private func drawBack(_ ctx: inout GraphicsContext, _ halo: HaloSpec) {
        HaloArt.draw(.back, in: &ctx, center: halo.center, scale: halo.scale, opacity: halo.opacity)
    }

    private func drawFront(_ ctx: inout GraphicsContext, _ halo: HaloSpec, _ f: Frame) {
        HaloArt.draw(.front, in: &ctx, center: halo.center, scale: halo.scale, opacity: halo.opacity)
        if reduceMotion {
            HaloArt.drawStill(in: &ctx, center: halo.center, scale: halo.scale, opacity: halo.opacity)
        } else {
            HaloArt.drawSparkle(in: &ctx, center: halo.center, scale: halo.scale, opacity: halo.opacity, time: f.t * f.sparkleSpeed + halo.shift)
        }
    }

    // MARK: Figure

    /// The picture of the page, which comes up as the service goes on (with it off the page is the button alone); it floats and, for the dog, sways a little.
    private func drawFigure(_ ctx: inout GraphicsContext, figure: CGPoint, lit: Double, sway: Double) {
        let folder: String, size: CGSize
        switch art {
        case .hood: folder = "hood"; size = CGSize(width: 128, height: 154)
        case .screen: folder = "media-scene"; size = CGSize(width: 160, height: 132)
        case .power: return
        }
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        ctx.drawLayer { layer in
            layer.translateBy(x: figure.x, y: figure.y)
            layer.rotate(by: .degrees(sway))
            if let on = ArtLibrary.shared.image(folder, "on.png"), lit > 0.003 {
                layer.opacity = lit
                layer.draw(Image(decorative: on, scale: 2), in: rect)
            }
        }
    }

    // MARK: Plane

    /// The paper plane that wanders round the dog, in one of four layers, with depth.
    private func drawPlane(_ ctx: inout GraphicsContext, _ f: Frame, figure: CGPoint, band: Int, opacity: Double) {
        let plane = motion.plane
        guard art == .hood, plane.band == band, opacity > 0.003 else { return }
        let frames = ArtLibrary.shared.sequence("paper-plane", pattern: "bank-%02d.png", frames: 13)
        guard frames.count == 13 else { return }
        let z = plane.z
        let k = 1 + 0.08 * z
        let cy = -8.0
        let position = CGPoint(x: figure.x + plane.x * k, y: figure.y + (plane.y - cy) * k + cy + 0.8 * sin(1.3 * f.t))
        let scale = 0.88 * (1 + 0.17 * z) * (1 + 0.04 * sin(0.21 * f.t))
        let alpha = (0.72 + 0.28 * (z + 1) / 2) * opacity
        let index = min(max((plane.bank + 36) / 6, 0), 12)
        let lower = min(Int(index.rounded(.down)), 11), mix = index - Double(lower)
        var outer = ctx
        outer.opacity = alpha
        outer.drawLayer { layer in
            layer.translateBy(x: position.x, y: position.y)
            layer.rotate(by: .radians(plane.heading + .pi / 2))
            layer.scaleBy(x: scale, y: scale)
            let rect = CGRect(x: -32, y: -32, width: 64, height: 64)
            // The neighbouring bank pictures dissolve over an opaque lower one, so that the plane never gets thinner for a moment.
            layer.draw(Image(decorative: frames[lower], scale: 2), in: rect)
            if mix > 0.002 {
                layer.drawLayer { upper in
                    upper.opacity = mix
                    upper.draw(Image(decorative: frames[lower + 1], scale: 2), in: rect)
                }
            }
        }
    }
}
