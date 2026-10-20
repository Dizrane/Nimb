import SwiftUI

/// The top of the home page of the desktop window: a stack of halos (one for each service that works), the title, the subtitle
/// and the one button that switches everything. The dog belongs to the Telegram page only. Made from the pictures of the art studio, as in
/// `art-studio/deliver/desktop-layout/reference.html`; `scale` makes it larger or smaller.
struct HomeHero: View {
    var scale: CGFloat = 1

    @ObservedObject private var all = AllServices.shared
    @ObservedObject private var gate = AnimationGate.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion = MascotMotion()

    private var bleed: CGFloat { 70 * scale }
    private var count: Int { all.onCount }
    private var busy: Bool { all.isBusy }

    private var title: String {
        if busy { return "Подождите" }
        if all.allOn { return "Всё включено" }
        return count == 0 ? "Выключено" : "Включено частично"
    }

    private var subtitle: String {
        if busy { return "Подтвердите пароль администратора, если macOS попросит" }
        if all.allOn { return "Нейросети, Telegram, YouTube и Discord работают." }
        return count == 0 ? "Одна кнопка включает нейросети, Telegram, YouTube и Discord." : "Включите остальное кнопкой или переключателями."
    }

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: motion.moving ? 1.0 / 30 : 1.0 / 20,
                                    paused: !(all.effectiveCount > 0 || motion.moving) || reduceMotion && !motion.moving || !gate.shouldRun(brief: motion.moving))) { context in
                // The canvas is larger than the stage by `bleed` on every side, so that the glow of the halos is not cut by a
                // straight edge; the layout still sees the stage.
                Canvas { ctx, _ in
                    ctx.translateBy(x: bleed, y: bleed)
                    draw(&ctx, size: CGSize(width: 220 * scale, height: 150 * scale), date: context.date)
                }
                .frame(width: 220 * scale + 2 * bleed, height: 150 * scale + 2 * bleed)
            }
            .padding(-bleed)
            .frame(width: 220 * scale, height: 150 * scale)
            .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 22 + 8 * scale, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                .contentTransition(.opacity)
                .padding(.top, 6)

            Text(subtitle)
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            Button { if all.allOn { all.disableAll() } else { all.enableAll() } } label: {
                HStack(spacing: 8) {
                    if all.isRunning { ProgressView().controlSize(.small).tint(.black) }
                    Text(all.allOn ? "Выключить всё" : "Включить всё")
                        .font(.system(size: 13 + 2 * (scale - 1), weight: .semibold))
                }
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 14 + 10 * (scale - 1))
                .padding(.vertical, 6 + 3 * (scale - 1))
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(busy ? 0.55 : 0.92)))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(busy)
            .padding(.top, 12)
        }
        .animation(.easeInOut(duration: 0.35), value: title)
        .onAppear { motion.set(rings: all.effectiveCount) }
        .onChange(of: all.effectiveCount) { motion.set(rings: $0) }
    }

    // MARK: Canvas

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let t = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let middle = size.width / 2
        let multiplier = [0.80, 0.92, 1.0]

        // The halos, lowest first.
        struct Ring { var center: CGPoint; var scale: CGFloat; var opacity: Double; var shift: Double }
        let rings: [Ring] = (0..<3).map { i in
            let value = motion.ring(i, at: date)
            let breathe = reduceMotion ? 1 : 0.93 + 0.07 * sin(1.7 * t - 0.8 * Double(i))
            let size = reduceMotion ? 1 : 1 + 0.012 * sin(1.3 * t - 0.8 * Double(i))
            let drop = reduceMotion ? 0 : CGFloat(value - 1) * 18 * scale
            return Ring(center: CGPoint(x: middle, y: (84 - 22 * CGFloat(i) + 8) * scale + drop),
                        scale: (0.78 - 0.055 * CGFloat(i)) * scale * CGFloat(size),
                        opacity: value * multiplier[i] * breathe,
                        shift: Double(i) * 0.37)
        }
        for ring in rings {
            HaloArt.draw(.back, in: &ctx, center: ring.center, scale: ring.scale, opacity: ring.opacity)
            HaloArt.draw(.front, in: &ctx, center: ring.center, scale: ring.scale, opacity: ring.opacity)
            if reduceMotion {
                HaloArt.drawStill(in: &ctx, center: ring.center, scale: ring.scale, opacity: ring.opacity)
            } else {
                HaloArt.drawSparkle(in: &ctx, center: ring.center, scale: ring.scale, opacity: ring.opacity, time: t + ring.shift)
            }
        }
    }
}
