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
        VStack(spacing: 0) {
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

            ScrollView {
                VStack(spacing: 10) {
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
                    Text("Туннель создаёт системное подключение и меняет маршруты, поэтому первая установка просит пароль администратора. Основано на amneziawg-go (MIT).")
                        .font(Typo.small)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
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
            Text("Nimb создаст для этого Mac собственный анонимный аккаунт Cloudflare WARP со своими ключами (личных данных он не передаёт), настроит туннель и запросит пароль администратора. Вводить ничего не нужно. Включая, вы принимаете условия Cloudflare WARP.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Условия Cloudflare WARP", destination: WarpTerms.url)
                .font(Typo.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }

    private var checkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Проверка")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            if warp.checks.isEmpty {
                Text("Запросит у YouTube и Discord короткий ответ и покажет, дошёл ли он. Голосовые каналы Discord так проверить нельзя, их проверьте в самом Discord.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(warp.checks) { check in
                HStack(spacing: 7) {
                    Image(systemName: check.ok ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(check.ok ? Theme.ok : Theme.bad)
                    Text(check.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(check.result).font(Typo.mono).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Spacer()
                if warp.isChecking { ProgressView().controlSize(.small) }
                OutlineButton(title: "Проверить YouTube и Discord", color: Theme.textPrimary, action: warp.runChecks)
                    .disabled(warp.isChecking)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.ok, tintOpacity: 0.03, borderOpacity: 0.28, radius: 10)
    }

    /// The tunnel asks for the administrator password each time; the person may allow it without.
    private var passwordHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Включение туннеля каждый раз просит пароль. Можно разрешить включать и выключать его без пароля.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Без пароля", color: Theme.warn) { warp.setPasswordless(true) }
                .disabled(warp.isSettingAccess)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.warn, tintOpacity: 0.03, borderOpacity: 0.28, radius: 10)
    }

    private var removeRow: some View {
        HStack(spacing: 10) {
            Text("Ключи WARP созданы на этом Mac. Если туннель больше не нужен, их можно удалить вместе с аккаунтом.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            OutlineButton(title: "Удалить", color: Theme.bad, action: warp.remove)
        }
        .padding(.horizontal, 2)
    }
}
