import SwiftUI

/// The home page of the tabs layout: the halos and the button for everything on the left and, because there is no sidebar here,
/// a row for each service with its switch and a button that opens its page as a tab on the right.
struct HomeTabsPage: View {
    var body: some View {
        TwoColumns {
            HomeHero(scale: 1.0)
        } right: {
            VStack(spacing: Space.gap) {
                ForEach(AppPage.services) { ServiceRow(page: $0) }
            }
        }
    }
}

/// One service of the home page: its icon, name and state, a button for its page, and its switch.
private struct ServiceRow: View {
    let page: AppPage
    @ObservedObject private var all = AllServices.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button { PlayableIcon.play(page, reduceMotion: reduceMotion) } label: {
                PlayableIcon(page: page, size: 38, dimmed: !all.isOn(page)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text(all.detail(page))
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            OutlineButton(title: "Настроить", color: Theme.textPrimary) {
                withAnimation(.easeOut(duration: 0.12)) { Navigation.shared.select(page) }
            }
            ServiceSwitch(page: page)
        }
        .card()
        .opacity(all.isLocked(page) && !all.isOn(page) ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }
}
