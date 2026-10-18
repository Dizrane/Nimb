import SwiftUI

/// The big power button: a glass sphere with rings that react to what the app is doing.
struct OrbButton: View {
    let mode: AppMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()

    private let diameter: CGFloat = 122

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
                orb(t: context.date.timeIntervalSinceReferenceDate)
                    .drawingGroup()
            }
            .frame(width: 214, height: 214)
            .contentShape(Circle().inset(by: 36))
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 }
        .animation(.easeInOut(duration: 0.8), value: mode)
        .animation(.easeOut(duration: 0.2), value: hover.value)
    }

    private func orb(t: Double) -> some View {
        let active = mode != .off
        let breath = 1 + sin(t * 1.6) * 0.012
        return ZStack {
            // Expanding rings: slow when on, fast when scanning.
            if active && !reduceMotion {
                let speed = mode == .probing ? 0.55 : mode == .on ? 0.22 : 0.4
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(mode.accent.opacity((1 - phase) * 0.5), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(1 + phase * 0.72)
                }
            }

            // Soft halo.
            Circle()
                .fill(RadialGradient(colors: [mode.accent.opacity(active ? 0.55 : 0.40), .clear],
                                     center: .center, startRadius: diameter * 0.35, endRadius: diameter * 0.95))
                .frame(width: diameter * 1.9, height: diameter * 1.9)

            // Rotating light ring.
            Circle()
                .strokeBorder(
                    AngularGradient(colors: [mode.accent.opacity(0), mode.accent, mode.secondary.opacity(0.1), mode.accent.opacity(0)],
                                    center: .center),
                    lineWidth: 3.5
                )
                .frame(width: diameter + 16, height: diameter + 16)
                .rotationEffect(.degrees(reduceMotion ? 0 : t * (mode == .probing ? 140 : mode == .busy ? 220 : 28)))
                .opacity(active ? 1 : 0.55)

            // Glass sphere.
            Circle()
                .fill(
                    LinearGradient(colors: [mode.accent.opacity(active ? 0.95 : 0.85), mode.secondary.opacity(active ? 0.85 : 0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.06)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                )
                .overlay(
                    // Specular highlight.
                    Ellipse()
                        .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: diameter * 0.62, height: diameter * 0.34)
                        .offset(y: -diameter * 0.30)
                        .blur(radius: 2)
                )
                .shadow(color: mode.accent.opacity(active ? 0.7 : 0.45), radius: active ? 28 : 20, y: 6)
                .scaleEffect((hover.value ? 1.04 : 1) * breath)

            if mode == .busy {
                ProgressView().controlSize(.large).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .scaleEffect(hover.value ? 1.04 : 1)
            }
        }
    }
}
