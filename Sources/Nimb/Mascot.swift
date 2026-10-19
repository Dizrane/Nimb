import SwiftUI

/// What stands under the halo on a page.
enum MascotArt: Equatable {
    /// The hooded dog of the Telegram page, a hand drawing.
    case hood
    /// A black screen with a play button and a chat bubble, drawn in the same ink: YouTube and Discord.
    case screen
}

/// The big switch of the Telegram and YouTube/Discord pages, made like the one of the DNS page: a figure under the halo
/// of Nimb. The halo comes down and the figure lights up when the service is on; a small power button sits below.
struct MascotHero: View {
    let art: MascotArt
    let isOn: Bool
    let isBusy: Bool
    let title: String
    let subtitle: String
    let accessibility: String
    var disabled = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()

    /// Where the crown of the figure is, relative to the middle of the stage, and how large the halo is around it.
    private let stageHeight: CGFloat = 208
    private var haloY: CGFloat { art == .hood ? -50 : -43 }
    private var haloScale: CGFloat { art == .hood ? 0.70 : 0.88 }

    var body: some View {
        let lit: Double = isOn ? 1 : 0
        let h: Double = hover.value ? 1 : 0
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.05 + 0.13 * lit + 0.04 * h * lit), .clear], center: .center, startRadius: 8, endRadius: 128))
                        .frame(width: 270, height: 270)
                        .offset(y: 4)

                    haloImage(HaloImages.shared.back)
                        .opacity(lit)
                        .offset(y: haloY + (isOn ? 0 : -18))

                    figure(lit: lit, hover: h)
                        .offset(y: 2)

                    haloImage(HaloImages.shared.front)
                        .opacity(lit)
                        .offset(y: haloY + (isOn ? 0 : -18))

                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isOn || reduceMotion || scenePhase != .active)) { context in
                        Canvas { ctx, size in
                            let place = (center: CGPoint(x: size.width / 2, y: size.height / 2 + haloY), scale: haloScale)
                            HaloSparks.draw(&ctx, place, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate, spin: 1, strength: 1)
                        }
                        .allowsHitTesting(false)
                    }
                    .opacity(lit)

                    badge(hover: h).offset(y: 84)
                }
                .frame(width: 320, height: stageHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)
            .onHover { hover.value = $0 }
            .animation(.easeInOut(duration: 1.0), value: isOn)
            .animation(.easeInOut(duration: 0.4), value: hover.value)
            .accessibilityLabel(accessibility)

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

    private func haloImage(_ image: CGImage) -> some View {
        let size = HaloImages.shared.size
        return Image(decorative: image, scale: HaloImages.shared.pixelScale)
            .resizable()
            .frame(width: size.width * haloScale, height: size.height * haloScale)
            .allowsHitTesting(false)
    }

    /// The figure itself: dim and plain while off, with a light rim and a glow once on.
    @ViewBuilder
    private func figure(lit: Double, hover: Double) -> some View {
        let rim = 0.22 + 0.45 * lit + 0.15 * hover
        Group {
            switch art {
            case .hood: HoodArt()
            case .screen: ScreenArt()
            }
        }
        .shadow(color: .white.opacity(rim * 0.8), radius: 1)
        .shadow(color: .white.opacity(0.08 + 0.16 * lit), radius: 10)
        .opacity(0.62 + 0.38 * lit)
        .scaleEffect(0.96 + 0.04 * lit)
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

// MARK: - Art

/// Shared look of the figures: black satin lit from the upper left, a thin light rim, pearl white for the faces.
private enum Satin {
    static let pearl = Gradient(colors: [Color(white: 0.99), Color(white: 0.86), Color(white: 0.66)])

    static func black(from: CGPoint, to: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: Color(white: 0.22), location: 0), .init(color: Color(white: 0.075), location: 0.45), .init(color: Color(white: 0.015), location: 1)]),
                        startPoint: from, endPoint: to)
    }

    static func rim(from: CGPoint, to: CGPoint, strength: Double = 1) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color.white.opacity(0.65 * strength), Color.white.opacity(0.10 * strength), Color.white.opacity(0.22 * strength)]),
                        startPoint: from, endPoint: to)
    }
}

/// The hooded dog of the Telegram page: a satin black hood, a pearl face and a glossy nose, drawn from curves.
struct HoodArt: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }

            var hood = Path()
            hood.move(to: P(0.52, 0.012))
            hood.addCurve(to: P(0.955, 0.60), control1: P(0.60, 0.012), control2: P(0.90, 0.25))
            hood.addCurve(to: P(0.99, 0.945), control1: P(0.985, 0.72), control2: P(1.0, 0.85))
            hood.addCurve(to: P(0.01, 0.945), control1: P(0.80, 1.012), control2: P(0.20, 1.012))
            hood.addCurve(to: P(0.045, 0.60), control1: P(0.0, 0.85), control2: P(0.015, 0.72))
            hood.addCurve(to: P(0.52, 0.012), control1: P(0.10, 0.25), control2: P(0.43, 0.012))
            hood.closeSubpath()

            var face = Path()
            face.move(to: P(0.50, 0.585))
            face.addCurve(to: P(0.185, 0.66), control1: P(0.42, 0.485), control2: P(0.22, 0.49))
            face.addCurve(to: P(0.50, 0.935), control1: P(0.15, 0.81), control2: P(0.28, 0.90))
            face.addCurve(to: P(0.815, 0.66), control1: P(0.72, 0.90), control2: P(0.85, 0.81))
            face.addCurve(to: P(0.50, 0.585), control1: P(0.78, 0.49), control2: P(0.58, 0.485))
            face.closeSubpath()

            // The hood: a clean black shape lit from the upper left, with one thin rim of light.
            ctx.fill(hood, with: Satin.black(from: P(0.15, 0.05), to: P(0.95, 1.0)))
            ctx.drawLayer { l in
                l.clip(to: hood)
                l.fill(Path(ellipseIn: CGRect(x: -0.1 * w, y: -0.05 * h, width: 0.95 * w, height: 0.75 * h)),
                       with: .radialGradient(Gradient(colors: [Color.white.opacity(0.13), .clear]), center: P(0.32, 0.22), startRadius: 0, endRadius: 0.5 * w))
            }
            ctx.stroke(hood, with: Satin.rim(from: P(0.1, 0.1), to: P(0.95, 0.95)), lineWidth: 1)

            // The face: pearl, with the shadow of the hood falling on its upper edge.
            ctx.fill(face, with: .linearGradient(Satin.pearl, startPoint: P(0.5, 0.52), endPoint: P(0.5, 0.95)))
            ctx.drawLayer { l in
                l.clip(to: face)
                l.translateBy(x: 0, y: 0.03 * h)
                l.addFilter(.blur(radius: 0.03 * h))
                l.stroke(face, with: .color(.black.opacity(0.5)), lineWidth: 0.09 * w)
            }
            ctx.stroke(face, with: .color(.black.opacity(0.55)), lineWidth: 0.8)

            // The nose: glossy black with a small light on it.
            let nose = CGRect(x: 0.35 * w, y: 0.685 * h, width: 0.30 * w, height: 0.19 * h)
            ctx.fill(Path(ellipseIn: nose), with: .radialGradient(
                Gradient(colors: [Color(white: 0.34), Color(white: 0.05), Color(white: 0.0)]),
                center: CGPoint(x: nose.minX + nose.width * 0.38, y: nose.minY + nose.height * 0.25), startRadius: 0, endRadius: nose.width * 0.7))
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 1))
                l.fill(Path(ellipseIn: CGRect(x: nose.minX + nose.width * 0.2, y: nose.minY + nose.height * 0.12, width: nose.width * 0.34, height: nose.height * 0.22)),
                       with: .color(.white.opacity(0.5)))
            }
        }
        .frame(width: 94, height: 118)
    }
}

/// A black screen with a glowing play button and a pearl Discord mark: YouTube and Discord, in the same material as the dog.
struct ScreenArt: View {
    var body: some View {
        Canvas { ctx, size in
            let screen = CGRect(x: 6, y: 6, width: 126, height: 88)
            let bezel = Path(roundedRect: screen, cornerRadius: 24, style: .continuous)
            let display = Path(roundedRect: screen.insetBy(dx: 7, dy: 7), cornerRadius: 17, style: .continuous)

            // The bezel.
            ctx.fill(bezel, with: Satin.black(from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY)))
            ctx.stroke(bezel, with: Satin.rim(from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY)), lineWidth: 1)

            // The glass: dark, with a faint light from above and a diagonal reflection.
            ctx.fill(display, with: .linearGradient(Gradient(colors: [Color(white: 0.115), Color(white: 0.02)]),
                                                    startPoint: CGPoint(x: screen.midX, y: screen.minY), endPoint: CGPoint(x: screen.midX, y: screen.maxY)))
            ctx.drawLayer { l in
                l.clip(to: display)
                var band = Path()
                band.move(to: CGPoint(x: screen.minX + 14, y: screen.maxY))
                band.addLine(to: CGPoint(x: screen.minX + 52, y: screen.minY))
                band.addLine(to: CGPoint(x: screen.minX + 76, y: screen.minY))
                band.addLine(to: CGPoint(x: screen.minX + 38, y: screen.maxY))
                band.closeSubpath()
                l.fill(band, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.07), Color.white.opacity(0.0)]),
                                                   startPoint: CGPoint(x: screen.minX + 20, y: screen.maxY), endPoint: CGPoint(x: screen.minX + 70, y: screen.minY)))
            }
            ctx.stroke(display, with: .color(.white.opacity(0.10)), lineWidth: 0.8)

            // The play button: a pearl triangle with rounded corners, glowing.
            let c = CGPoint(x: screen.midX - 3, y: screen.midY - 1)
            var play = Path()
            play.move(to: CGPoint(x: c.x - 11, y: c.y - 17))
            play.addLine(to: CGPoint(x: c.x + 17, y: c.y))
            play.addLine(to: CGPoint(x: c.x - 11, y: c.y + 17))
            play.closeSubpath()
            let pearl = GraphicsContext.Shading.linearGradient(Satin.pearl, startPoint: CGPoint(x: c.x, y: c.y - 17), endPoint: CGPoint(x: c.x, y: c.y + 17))
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .white.opacity(0.55), radius: 9))
                l.fill(play, with: pearl)
                l.stroke(play, with: pearl, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            // The Discord mark: pearl, with a dark outline that separates it from the screen, and two dark eyes.
            let mark = CGRect(x: 82, y: 64, width: 66, height: 50)
            func M(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: mark.minX + x / 100 * mark.width, y: mark.minY + y / 76 * mark.height) }
            var logo = Path()
            logo.move(to: M(21, 7))
            logo.addCurve(to: M(41, 9), control1: M(29, 3), control2: M(36, 5))
            logo.addCurve(to: M(59, 9), control1: M(47, 8), control2: M(53, 8))
            logo.addCurve(to: M(79, 7), control1: M(64, 5), control2: M(71, 3))
            logo.addCurve(to: M(98, 58), control1: M(90, 15), control2: M(97, 36))
            logo.addCurve(to: M(75, 70), control1: M(91, 63), control2: M(83, 67))
            logo.addCurve(to: M(70, 62), control1: M(73, 67), control2: M(71, 64))
            logo.addCurve(to: M(30, 62), control1: M(57, 66), control2: M(43, 66))
            logo.addCurve(to: M(25, 70), control1: M(29, 64), control2: M(27, 67))
            logo.addCurve(to: M(2, 58), control1: M(17, 67), control2: M(9, 63))
            logo.addCurve(to: M(21, 7), control1: M(3, 36), control2: M(10, 15))
            logo.closeSubpath()
            ctx.stroke(logo, with: .color(.black), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            ctx.fill(logo, with: .linearGradient(Satin.pearl, startPoint: CGPoint(x: mark.midX, y: mark.minY), endPoint: CGPoint(x: mark.midX, y: mark.maxY)))
            for x in [35.0, 65.0] {
                let eye = CGRect(x: M(x, 0).x - 4.6, y: M(0, 30).y, width: 9.2, height: 12.5)
                ctx.fill(Path(ellipseIn: eye), with: .linearGradient(Gradient(colors: [Color(white: 0.30), Color(white: 0.04)]), startPoint: CGPoint(x: eye.midX, y: eye.minY), endPoint: CGPoint(x: eye.midX, y: eye.maxY)))
            }
        }
        .frame(width: 152, height: 118)
    }
}
