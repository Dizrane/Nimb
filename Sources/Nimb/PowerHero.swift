import SwiftUI

/// The big switch at the top of the Telegram and YouTube/Discord pages, drawn like the one on the Neural networks page
/// but without the planet: a graphite disc that turns green when the service is on.
struct PowerHero: View {
    let isOn: Bool
    let isBusy: Bool
    let title: String
    let subtitle: String
    let accessibility: String
    var disabled = false
    let action: () -> Void

    @StateObject private var hover = Flag()

    var body: some View {
        let h: Double = hover.value ? 1 : 0
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Theme.ok.opacity(isOn ? 0.30 : 0), .clear], center: .center, startRadius: 30, endRadius: 112))
                        .frame(width: 224, height: 224)
                    Circle()
                        .strokeBorder((isOn ? Theme.ok : Color.white).opacity(isOn ? 0.55 : 0.12 + 0.16 * h), lineWidth: 1)
                        .frame(width: 146, height: 146)
                    Circle()
                        .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(colors: [(isOn ? Theme.ok : Color.white).opacity(0.55 + 0.3 * h), Color.white.opacity(0.10 + 0.1 * h)], startPoint: .top, endPoint: .bottom),
                                lineWidth: 1.2
                            )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(color: .black.opacity(0.6), radius: 16, y: 9)
                    if isBusy {
                        ProgressView().controlSize(.regular).tint(.white)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(isOn ? Theme.ok : Color.white.opacity(0.9 + 0.1 * h))
                    }
                }
                .frame(width: 224, height: 176)
                .contentShape(Circle().inset(by: 30))
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)
            .onHover { hover.value = $0 }
            .animation(.easeInOut(duration: 0.45), value: hover.value)
            .animation(.easeInOut(duration: 0.6), value: isOn)
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
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.35), value: title)
    }
}
