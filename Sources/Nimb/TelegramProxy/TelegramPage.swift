import SwiftUI

/// The Telegram page of the window: switch the proxy on, connect Telegram Desktop to it, see how it is doing.
struct TelegramPage: View {
    @ObservedObject var telegram: TelegramProxyModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Telegram")
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
                    if telegram.isRunning { connectCard }
                    optionsCard
                    if let message = telegram.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                    Text("Прокси слушает только этот Mac (127.0.0.1) и ничего не открывает наружу. Идея и принцип работы: TG WS Proxy от Flowseal (MIT).")
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
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(telegram.isRunning ? Theme.ok : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                Text("Прокси для Telegram")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(telegram.isRunning ? "Работает" : (telegram.isStarting ? "Запускаю…" : "Выключен"))
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(telegram.isRunning
                 ? "127.0.0.1:\(String(telegram.port)). Telegram Desktop ходит через этот прокси к серверам Telegram по WebSocket, который провайдеры замедляют меньше."
                 : "Ускоряет Telegram там, где он грузится медленно или не открывается. Включите и подключите Telegram Desktop по кнопке ниже.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if telegram.isRunning {
                let s = telegram.stats
                Text("Соединений: \(s.totalConnections) (сейчас \(s.activeConnections)) · WebSocket \(s.webSocket) · напрямую \(s.directTCP) · ошибок \(s.failures)")
                    .font(Typo.mono)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("↑ \(bytes(s.bytesUp))   ↓ \(bytes(s.bytesDown))")
                    .font(Typo.mono)
                    .foregroundStyle(Theme.textSecondary)
                if s.wrongSecret > 0 {
                    Text("Отклонено подключений с чужим secret: \(s.wrongSecret). В Telegram, похоже, указан другой прокси на этом порту: нажмите «Открыть в Telegram» ниже и подтвердите, а старый прокси удалите.")
                        .font(Typo.small)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                OutlineButton(title: telegram.isRunning ? "Остановить" : "Включить",
                              color: telegram.isRunning ? Theme.warn : Theme.textPrimary,
                              action: telegram.toggle)
                    .disabled(telegram.isStarting)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Подключить Telegram Desktop")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("Кнопка откроет Telegram с окном «Добавить прокси»: подтвердите его. Если не сработало, скопируйте ссылку и отправьте себе в «Избранное», затем нажмите на неё.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Вручную: Настройки → Продвинутые → Тип подключения → Прокси → MTProto, сервер 127.0.0.1, порт \(String(telegram.port)).")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                OutlineButton(title: "Скопировать ссылку", color: Theme.textPrimary, action: telegram.copyLink)
                OutlineButton(title: "Открыть в Telegram", color: Theme.ok, action: telegram.openInTelegram)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.ok, tintOpacity: 0.03, borderOpacity: 0.28, radius: 10)
    }

    private var optionsCard: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Запускать вместе с Nimb")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text("Прокси включится при каждом открытии Nimb. Пока он работает, в строке меню виден значок Nimb, а окно можно закрыть.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $telegram.autoStart)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }

    private func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
}
