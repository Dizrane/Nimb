import SwiftUI

/// The left panel of the sidebar layout: «Главная», the three services with a switch each, and «Настройки» at the bottom.
struct SidebarView: View {
    static let width: CGFloat = 226

    @ObservedObject private var nav = Navigation.shared
    @ObservedObject private var all = AllServices.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(.home)

            Text("Сервисы")
                .sectionLabel()
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)

            ForEach(AppPage.services) { row($0) }

            Spacer(minLength: 12)
            row(.settings)
        }
        .padding(.top, 46)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
    }

    private func row(_ page: AppPage) -> some View {
        let selected = nav.page == page
        return HStack(spacing: 8) {
            Button {
                PlayableIcon.play(page, reduceMotion: reduceMotion)
                withAnimation(.easeOut(duration: 0.12)) { nav.select(page) }
            } label: {
                HStack(spacing: 6) {
                    icon(page).frame(width: 26, height: 24)
                    Text(page.title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.title)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if page.isService { ServiceSwitch(page: page) }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.11 : 0)))
    }

    @ViewBuilder
    private func icon(_ page: AppPage) -> some View {
        if page == .home {
            RingsIcon(count: all.effectiveCount, selected: nav.page == .home)
        } else {
            PlayableIcon(page: page, size: 32, dimmed: page.isService && !all.isOn(page))
        }
    }
}

/// The three small rings of the home page, one for each service, bright when the service works.
struct RingsIcon: View {
    let count: Int
    let selected: Bool

    var body: some View {
        Canvas { ctx, size in
            HeaderRing.drawStack(&ctx, center: CGPoint(x: size.width / 2, y: size.height / 2), count: count, selected: selected)
        }
        .frame(width: 28, height: 22)
    }
}
