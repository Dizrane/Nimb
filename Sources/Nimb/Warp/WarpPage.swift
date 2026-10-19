import SwiftUI

/// The WARP page: bring the tunnel from AmneziaWG over, switch it on and off, check YouTube and Discord.
struct WarpPage: View {
    @ObservedObject var warp: WarpTunnelModel
    let close: () -> Void
    @StateObject private var replacing = Flag()

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
                    if warp.phase == .notInstalled || replacing.value { importCard }
                    if warp.isInstalled && !replacing.value { manageCard }
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
            HStack {
                Spacer()
                if warp.isWorking { ProgressView().controlSize(.small) }
                OutlineButton(title: warp.isOn ? "Выключить" : "Включить",
                              color: warp.isOn ? Theme.warn : Theme.textPrimary,
                              action: warp.toggle)
                    .disabled(!warp.isInstalled || warp.isWorking)
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

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Перенести туннель из AmneziaWG")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("В AmneziaWG откройте туннель WARP → «Изменить», выделите весь текст (⌘A), скопируйте (⌘C) и нажмите «Вставить из буфера». Ключ останется на этом Mac, в папке, которую читает только администратор.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $warp.draft)
                .font(Typo.mono)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            if let error = warp.parseError {
                Text(error).font(Typo.small).foregroundStyle(Theme.bad).fixedSize(horizontal: false, vertical: true)
            }
            if let summary = warp.preview {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Сервер: \(summary.endpoint)")
                    Text("Адрес: \(summary.addresses.joined(separator: ", "))")
                    Text(summary.isFullTunnel ? "Маршрут: весь трафик" : "Маршрут: \(networks(summary.allowedIPs.count))")
                    if !summary.obfuscation.isEmpty { Text("Камуфляж: \(summary.obfuscation.joined(separator: ", "))") }
                }
                .font(Typo.mono)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                if !summary.ignored.isEmpty {
                    Text("Не перенесено: \(summary.ignored.joined(separator: ", "))")
                        .font(Typo.small)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if replacing.value { OutlineButton(title: "Отмена", color: Theme.textSecondary) { replacing.value = false; warp.draft = "" } }
                Spacer()
                OutlineButton(title: "Вставить из буфера", color: Theme.textPrimary, action: warp.pasteFromClipboard)
                OutlineButton(title: "Установить", color: Theme.ok) {
                    warp.install()
                    replacing.value = false
                }
                .disabled(warp.preview == nil || warp.isWorking)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }

    private func networks(_ count: Int) -> String {
        let last = count % 10, lastTwo = count % 100
        let word = last == 1 && lastTwo != 11 ? "сеть" : (2...4).contains(last) && !(12...14).contains(lastTwo) ? "сети" : "сетей"
        return "\(count) \(word)"
    }

    private var manageCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Настройки туннеля установлены")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text("Помощник и ключ лежат в /usr/local/libexec/nimb, читать их может только администратор.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                OutlineButton(title: "Заменить", color: Theme.textPrimary) { replacing.value = true }
                OutlineButton(title: "Удалить", color: Theme.bad, action: warp.remove)
            }
            .disabled(warp.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }
}
