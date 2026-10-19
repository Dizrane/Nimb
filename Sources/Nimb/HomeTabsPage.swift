import SwiftUI

/// The home page of the tabs layout: the dog under its halos, the button for everything and, because there is no sidebar here,
/// a row for each service with its switch and a button that opens its page as a tab.
struct HomeTabsPage: View {
    @ObservedObject private var all = AllServices.shared
    @ObservedObject private var nav = Navigation.shared

    var body: some View {
        FitOrScroll {
            VStack(spacing: Space.gap + 6) {
                HomeHero(scale: 0.8)
                    .padding(.top, 8)
                VStack(spacing: Space.gap) {
                    ForEach(AppPage.services) { ServiceRow(page: $0) }
                }
                .frame(maxWidth: 440)
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One service of the home page: its icon, name and state, a button for its page, and its switch.
private struct ServiceRow: View {
    let page: AppPage
    @ObservedObject private var all = AllServices.shared

    var body: some View {
        HStack(spacing: 12) {
            if let art = page.iconFile(dimmed: !all.isOn(page)) { ArtImage(folder: art.folder, file: art.file, size: 38) }
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
