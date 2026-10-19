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

/// The big switch of the Telegram and YouTube/Discord pages, made like the one of the DNS page: a figure under the halo
/// of Nimb. The halo comes down and the figure lights up when the service is on; a small power button sits below.
struct MascotHero: View {
    let art: MascotArt
    let isOn: Bool
    let isBusy: Bool
    /// How much of the halo shines, 0 to 1. By default all of it while on, none while off; the home page uses the
    /// part of the services that are on.
    var level: Double? = nil
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
    private var haloY: CGFloat {
        switch art {
        case .hood: -49
        case .screen: -43
        case .power: -57
        }
    }
    private var haloScale: CGFloat {
        switch art {
        case .hood: 0.80
        case .screen: 0.92
        case .power: 0.96
        }
    }

    var body: some View {
        let lit: Double = level ?? (isOn ? 1 : 0)
        // With Reduce Motion the halo only fades in; it does not come down from above.
        let haloDrop: CGFloat = reduceMotion ? 0 : CGFloat(lit - 1) * 18
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
                        .offset(y: haloY + haloDrop)

                    figure(lit: lit, hover: h)
                        .offset(y: 2)

                    haloImage(HaloImages.shared.front)
                        .opacity(lit)
                        .offset(y: haloY + haloDrop)

                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: lit < 0.99 || reduceMotion || scenePhase != .active)) { context in
                        Canvas { ctx, size in
                            let place = (center: CGPoint(x: size.width / 2, y: size.height / 2 + haloY), scale: haloScale)
                            HaloSparks.draw(&ctx, place, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate, spin: 1, strength: 1)
                        }
                        .allowsHitTesting(false)
                    }
                    .opacity(lit)

                    if art != .power { badge(hover: h).offset(y: 84) }
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
