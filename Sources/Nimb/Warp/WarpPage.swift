import SwiftUI

/// The YouTube and Discord page: one switch for the WARP tunnel, a check that the two sites open.
struct WarpPage: View {
    @ObservedObject var warp: WarpTunnelModel

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
        case .on: return "Трафик идёт через Cloudflare WARP."
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
                action: warp.phase == .notInstalled ? warp.enable : warp.toggle
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
                    if warp.isInstalled && !warp.passwordless && !warp.isWorking { passwordHint }
                    if warp.isInstalled && !warp.isWorking { removeRow }
            }
        }
        .onAppear { warp.refresh(); warp.startWatching() }
        .onDisappear { warp.stopWatching() }
    }

    // MARK: Cards

    /// What happens on the first start, with the terms the person agrees to by pressing the button.
    private var firstStartCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Что произойдёт при включении")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("Nimb создаст для этого Mac анонимный аккаунт Cloudflare WARP и запросит пароль. Включая, вы принимаете условия Cloudflare WARP.")
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

    /// The tunnel asks for the administrator password each time; the person may allow it without.
    private var passwordHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Включение туннеля каждый раз просит пароль. Можно разрешить включать и выключать его без пароля.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Без пароля", color: Theme.textPrimary) { warp.setPasswordless(true) }
                .disabled(warp.isSettingAccess)
        }
        .card()
    }

    private var removeRow: some View {
        HStack(spacing: 10) {
            Text("Ключи туннеля созданы на этом Mac.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            OutlineButton(title: "Удалить", color: Theme.textSecondary, action: warp.remove)
        }
        .padding(.horizontal, 2)
    }
}
