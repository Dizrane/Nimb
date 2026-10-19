import SwiftUI

/// The WARP page: switch the tunnel on and off, check YouTube and Discord.
struct WarpPage: View {
    @ObservedObject var warp: WarpTunnelModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WARP")
                    .font(Typo.status)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: close) {
                    Text("Готово")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 10) {
                    statusCard
                    if warp.isOn { checkCard }
                    if warp.isInstalled { manageCard }
                    if let message = warp.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                    Text("Не включайте его одновременно с туннелем WARP в AmneziaWG: у них один ключ. Туннель создаёт системный интерфейс и меняет маршруты, поэтому включение просит пароль администратора. Основано на amneziawg-go (MIT).")
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

    private var statusText: String {
        switch warp.phase {
        case .unavailable: return "Недоступен"
        case .notInstalled: return "Не настроен"
        case .off: return "Выключен"
        case .working(let text): return text
        case .on(let interface): return "Работает (\(interface))"
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(warp.isOn ? Theme.ok : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                Text("Туннель WARP")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(warp.phase == .unavailable
                 ? "В этой сборке Nimb нет amneziawg-go, туннель недоступен. Соберите приложение через scripts/build_awg.sh или скачайте релиз."
                 : "Трафик идёт через Cloudflare WARP с камуфляжем AmneziaWG, чтобы YouTube и Discord открывались там, где их закрывает провайдер.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if warp.phase == .notInstalled {
                Text("Ничего вводить не нужно. При первом включении Nimb создаст для этого Mac собственный анонимный аккаунт WARP со своими ключами (личных данных он не передаёт) и спросит пароль администратора. Включая, вы принимаете условия Cloudflare WARP.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Условия Cloudflare WARP", destination: URL(string: "https://www.cloudflare.com/application/terms/")!)
                    .font(Typo.small)
            }
            HStack {
                Spacer()
                if warp.isWorking { ProgressView().controlSize(.small) }
                OutlineButton(title: warp.isOn ? "Выключить" : "Включить",
                              color: warp.isOn ? Theme.warn : Theme.textPrimary,
                              action: warp.phase == .notInstalled ? warp.enable : warp.toggle)
                    .disabled(warp.phase == .unavailable || warp.isWorking)
            }
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

    private var manageCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Туннель настроен для этого Mac")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text("Ключи созданы на этом Mac и лежат в /usr/local/libexec/nimb, читать их может только администратор. «Удалить» удаляет и аккаунт WARP.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            OutlineButton(title: "Удалить", color: Theme.bad, action: warp.remove)
                .disabled(warp.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }
}
