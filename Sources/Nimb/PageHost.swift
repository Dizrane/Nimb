import SwiftUI

/// The page that is open, in the room that the sidebar leaves for it: the pages of the services and the settings keep their
/// content and are held in a column that never gets wider than 440 pt, so that they look the same in a wide window.
struct PageHost: View {
    let page: AppPage

    @EnvironmentObject private var model: DNSViewModel
    @EnvironmentObject private var telegram: TelegramProxyModel
    @EnvironmentObject private var warp: WarpTunnelModel
    @ObservedObject private var onboarding = Onboarding.shared

    var body: some View {
        Group {
            switch page {
            case .home:
                HomeHero(scale: 1.25).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ai: wide { AIPage(model: model) }
            case .telegram: wide { TelegramPage(telegram: telegram) }
            case .media: wide { WarpPage(warp: warp) }
            case .settings: wide { SettingsView(model: model, onboarding: onboarding, warp: warp) }
            }
        }
        .transition(.opacity)
    }

    /// A page of the desktop window uses all the room it is given; it has its name on top.
    private func wide<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if page != .settings {
                Text(page.title)
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.page)
                    .padding(.top, 22)
                    .padding(.bottom, 2)
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
