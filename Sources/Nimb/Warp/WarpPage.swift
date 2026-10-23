import SwiftUI

/// The YouTube and Discord page: one switch for the WARP tunnel, a check that the two sites open.
struct WarpPage: View {
    @ObservedObject var warp: WarpTunnelModel
    @Environment(\.openWindow) private var openWindow

    private var title: String {
        switch warp.phase {
        case .unavailable: return "Недоступно"
        case .notInstalled, .off: return "Выключено"
        case .working: return "Подождите"
        case .on: return "Включено"
        }
    }

    private var subtitle: String {
        switch warp.phase {
        case .unavailable: return "В этой сборке Nimb нет туннеля. Скачайте приложение со страницы релизов."
        case .notInstalled: return "Включите, чтобы открывались YouTube и Discord. Всё настроится само."
        case .off: return "Включите, чтобы открывались YouTube и Discord."
        case .working(let text): return text
        case .on: return "Весь трафик этого Mac идёт через Cloudflare WARP. Если не открывается банк или Госуслуги, выключите туннель."
        }
    }

    var body: some View {
        TwoColumns {
            MascotHero(
                art: .screen,
                isOn: warp.isOn,
                isBusy: warp.isWorking,
                title: title,
                subtitle: subtitle,
                accessibility: warp.isOn ? "Выключить туннель WARP" : "Включить туннель WARP",
                disabled: warp.phase == .unavailable || warp.isWorking,
                action: { if warp.phase == .notInstalled { warp.enable() } else { warp.toggle() } }
            )
        } right: {
            VStack(spacing: Space.gap) {
                    if warp.isOn {
                        checkCard
                    } else if warp.phase == .notInstalled {
                        firstStartCard
                    }
                    if let message = warp.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                    sitesRow
            }
        }
        .onAppear { warp.refresh(); warp.startWatching() }
        .onDisappear { warp.stopWatching() }
    }

    // MARK: Cards

    /// A remark, not a block of the page: the list of everything the tunnel opens is behind the small «i».
    private var sitesRow: some View {
        HStack(spacing: 2) {
            Text("Туннель даёт доступ и к другим сервисам")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
            Button { openWindow(id: TunnelSitesWindow.windowID) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Что ещё открывает туннель")
            .accessibilityLabel("Что ещё открывает туннель")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    /// What happens on the first start, with the terms the person agrees to by pressing the button.
    private var firstStartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Что произойдёт при включении")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("Nimb создаст для этого Mac анонимный аккаунт Cloudflare WARP и запросит пароль. Пока туннель включён, через Cloudflare идёт весь трафик Mac, и некоторые сайты, например банки и Госуслуги, могут не открываться: тогда выключите туннель. Включая, вы принимаете условия Cloudflare WARP.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Условия Cloudflare WARP", destination: WarpTerms.url)
                .font(Typo.small)
        }
        .card(.neutral)
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Проверка")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            if warp.checks.isEmpty {
                Text("Проверит, открываются ли YouTube и Discord.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warp.checks) { check in
                CheckRow(check: check)
            }
            HStack {
                Spacer()
                if warp.isChecking { ProgressView().controlSize(.small) }
                OutlineButton(title: "Проверить YouTube и Discord", color: Theme.textPrimary, action: warp.runChecks)
                    .disabled(warp.isChecking)
            }
        }
        .card()
    }
}
