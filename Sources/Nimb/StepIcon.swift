import SwiftUI

/// An icon of a step or of a row (`Art/icon-*`): a black glass disc with a white sign. A tap plays its little story. With `halo`
/// the small halo of Nimb stands above it, as on the steps of the first set-up.
struct StepIcon: View {
    @ObservedObject var player: StepIconPlayer
    /// The size of the picture in points (the disc is three quarters of it).
    var size: CGFloat = 80
    /// The service is off: the dimmed picture.
    var dimmed = false
    var halo = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var gate = AnimationGate.shared

    private var canvasSize: CGSize {
        halo ? CGSize(width: size * 1.62, height: size * 1.3) : CGSize(width: size, height: size)
    }

    var body: some View {
        Button { player.play(reduceMotion: reduceMotion) } label: {
            TimelineView(.animation(minimumInterval: player.isPlaying ? 1.0 / 30 : 1.0 / 15, paused: !(player.isPlaying || halo) || reduceMotion || !gate.shouldRun(brief: player.isPlaying))) { context in
                Canvas { ctx, canvas in draw(&ctx, canvas, date: context.date) }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Показать анимацию значка")
    }

    private func draw(_ ctx: inout GraphicsContext, _ canvas: CGSize, date: Date) {
        let k = size / 80
        // The middle of the picture: lower on the canvas when the halo stands above it.
        let middle = CGPoint(x: canvas.width / 2, y: halo ? canvas.height - size / 2 - size * 0.02 : canvas.height / 2)
        if player.kind == .welcome {
            drawWelcome(&ctx, middle: middle, k: k, date: date)
            return
        }
        // The halo at rest above the picture: it breathes and its dust slides along the ring.
        let ring = CGPoint(x: middle.x, y: middle.y + WelcomeScan.rest * k)
        let life = haloLife(date)
        if halo { HaloArt.draw(.back, in: &ctx, center: ring, scale: WelcomeScan.restScale * k * life.scale, opacity: life.opacity) }
        drawPicture(&ctx, middle: middle, k: k, date: date)
        if halo { drawHaloFront(&ctx, center: ring, scale: WelcomeScan.restScale * k, date: date) }
    }

    /// The breathing of the small halo: the same as the large ones (opacity 0.93...1, scale within 1.2 %); still with Reduce Motion.
    private func haloLife(_ date: Date) -> (opacity: Double, scale: CGFloat) {
        if reduceMotion { return (1, 1) }
        let t = date.timeIntervalSinceReferenceDate
        return (0.93 + 0.07 * sin(1.7 * t), 1 + 0.012 * CGFloat(sin(1.3 * t)))
    }

    /// The near half of the small halo with the loop of dust along it.
    private func drawHaloFront(_ ctx: inout GraphicsContext, center: CGPoint, scale: CGFloat, date: Date) {
        let life = haloLife(date)
        HaloArt.draw(.front, in: &ctx, center: center, scale: scale * life.scale, opacity: life.opacity)
        if reduceMotion {
            HaloArt.drawStill(in: &ctx, center: center, scale: scale, opacity: life.opacity)
        } else {
            HaloArt.drawSparkle(in: &ctx, center: center, scale: scale * life.scale, opacity: life.opacity, time: date.timeIntervalSinceReferenceDate)
        }
    }

    private func picture(_ file: String) -> CGImage? { ArtLibrary.shared.image(player.kind.folder, file) }

    private func drawImage(_ image: CGImage?, in ctx: inout GraphicsContext, middle: CGPoint, k: CGFloat, opacity: Double = 1) {
        guard let image else { return }
        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.draw(Image(decorative: image, scale: 2), in: CGRect(x: middle.x - 40 * k, y: middle.y - 40 * k, width: 80 * k, height: 80 * k))
        }
    }

    private func drawPicture(_ ctx: inout GraphicsContext, middle: CGPoint, k: CGFloat, date: Date) {
        let kind = player.kind
        if player.showsSecond, let second = kind.second {
            drawImage(picture(kind.still), in: &ctx, middle: middle, k: k)
            drawImage(picture(second), in: &ctx, middle: middle, k: k)
        } else if let frame = player.frame(at: date) {
            drawImage(frame, in: &ctx, middle: middle, k: k)
        } else {
            drawImage(picture(dimmed ? kind.dimmed : kind.still), in: &ctx, middle: middle, k: k)
        }
    }

    // MARK: Welcome

    private func drawWelcome(_ ctx: inout GraphicsContext, middle: CGPoint, k: CGFloat, date: Date) {
        let playing = player.isPlaying && !reduceMotion
        let t = playing ? player.elapsed(at: date) : 0
        let p = playing ? WelcomeScan.progress(t) : 0
        let mode: WelcomeScan.Mode = player.taps % 2 == 1 ? .middle : .edge
        var ring = WelcomeScan.ring(p, mode)
        var offset = CGPoint.zero
        if playing && p >= 1 {
            if mode == .middle { offset = WelcomeScan.shudder(t) } else { ring.y += sin(1.6 * t) * 0.45 }
        }
        let ringCenter = CGPoint(x: middle.x + offset.x * k, y: middle.y + (ring.y + offset.y) * k)

        let life = haloLife(date)
        HaloArt.draw(.back, in: &ctx, center: ringCenter, scale: ring.scale * k * life.scale, opacity: life.opacity)
        drawImage(picture(dimmed ? "disc-off.png" : "disc.png"), in: &ctx, middle: middle, k: k)

        if player.showsSecond {
            drawImage(ArtLibrary.shared.image("icon-ai", "planet.png"), in: &ctx, middle: middle, k: k)
        } else if playing && p > 0 {
            let r = WelcomeScan.radius
            ctx.drawLayer { layer in
                layer.translateBy(x: middle.x, y: middle.y)
                layer.scaleBy(x: k, y: k)
                layer.clip(to: Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)))
                // What the ring has passed: everything above its near arc.
                var passed = Path()
                passed.move(to: CGPoint(x: -r - 1, y: -r - 2))
                passed.addLine(to: CGPoint(x: r + 1, y: -r - 2))
                var x = r + 1
                while x >= -(r + 1) {
                    passed.addLine(to: CGPoint(x: x, y: WelcomeScan.arcY(x, ring)))
                    x -= 1
                }
                passed.closeSubpath()
                layer.clip(to: passed)
                if mode == .edge {
                    if let planet = ArtLibrary.shared.image("icon-ai", "planet.png") {
                        layer.draw(Image(decorative: planet, scale: 2), in: CGRect(x: -40, y: -40, width: 80, height: 80))
                    }
                } else {
                    var y = -r
                    while y <= r {
                        var cx = -r
                        while cx <= r {
                            if cx * cx + y * y <= r * r {
                                let n = WelcomeScan.noise(x: cx, y: y, t: t, p: p)
                                layer.fill(Path(CGRect(x: cx, y: y, width: 2, height: 2)), with: .color(Color(white: n.grey / 255).opacity(n.alpha)))
                            }
                            cx += 2
                        }
                        y += 2
                    }
                }
            }
        }

        drawHaloFront(&ctx, center: ringCenter, scale: ring.scale * k, date: date)
    }
}
