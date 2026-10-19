import SwiftUI

/// The three things Nimb does, one page each.
enum AppTab: String, CaseIterable, Identifiable {
    case home, ai, telegram, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .ai: return "Нейросети"
        case .telegram: return "Telegram"
        case .media: return "YouTube и Discord"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .ai: return "sparkles"
        case .telegram: return "paperplane"
        case .media: return "play.rectangle"
        }
    }
}

/// Three switches at the top of the window. A green dot shows which of the three is working right now.
struct TabBar: View {
    @Binding var selection: AppTab
    let isOn: (AppTab) -> Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        if tab == .home {
                            Image(systemName: "house")
                                .font(.system(size: 13, weight: .regular))
                        } else {
                            Text(tab.title)
                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: tab == .home ? 40 : .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
                    .overlay(alignment: .topTrailing) {
                        if isOn(tab) && tab != .home {
                            Circle().fill(Theme.ok).frame(width: 5, height: 5).padding(5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(tab.title + (isOn(tab) ? ", включено" : ""))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 20)
    }
}

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

/// A short paragraph in a card, the building block of the pages below the big switch.
struct InfoCard: View {
    let title: String
    let text: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: tint, tintOpacity: tint == .white ? 0.02 : 0.03, borderOpacity: tint == .white ? 0.16 : 0.28, radius: 10)
    }
}
