import SwiftUI

/// The Telegram page: one switch for the proxy, one button that connects Telegram Desktop to it.
struct TelegramPage: View {
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject private var background = BackgroundMode.shared

    var body: some View {
        VStack(spacing: 0) {
            MascotHero(
                art: .hood,
                isOn: telegram.isRunning,
                isBusy: telegram.isStarting,
                title: telegram.isRunning ? "Включено" : (telegram.isStarting ? "Запускаю" : "Выключено"),
                subtitle: telegram.isRunning
                    ? "Прокси работает на этом Mac. Telegram ходит через него."
                    : "Включите, чтобы Telegram открывался и грузил файлы быстрее.",
                accessibility: telegram.isRunning ? "Остановить прокси для Telegram" : "Включить прокси для Telegram",
                disabled: telegram.isStarting,
                action: telegram.toggle
            )

            ScrollView {
                VStack(spacing: Space.gap) {
                    if telegram.isRunning {
                        connectCard
                        if !background.enabled { backgroundHint }
                        if telegram.stats.wrongSecret > 0 {
                            NoticeCard(lines: ["Telegram подключается с чужим ключом (\(telegram.stats.wrongSecret) раз): в нём, похоже, указан другой прокси на этом порту. Нажмите «Открыть в Telegram» и подтвердите, а старый прокси удалите."], color: Theme.warn, symbol: "exclamationmark.triangle")
                        }
                        statsLine
                    } else {
                        InfoCard(
                            title: "Как это работает",
                            text: "Включите прокси, затем нажмите «Открыть в Telegram» и подтвердите окно «Добавить прокси». Это нужно сделать один раз: дальше Telegram сам ходит через Nimb, пока он включён."
                        )
                    }
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
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.s)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Подключить Telegram")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("Кнопка откроет Telegram Desktop с окном «Добавить прокси»: подтвердите его. Если не сработало, скопируйте ссылку и отправьте себе в «Избранное», затем нажмите на неё.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                OutlineButton(title: "Скопировать ссылку", color: Theme.textPrimary, action: telegram.copyLink)
                OutlineButton(title: "Открыть в Telegram", color: Theme.ok, action: telegram.openInTelegram)
            }
        }
        .card(.ok)
    }

    /// Without it, closing the window or pressing Command-Q switches the proxy off, and Telegram stops working.
    private var backgroundHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Если закрыть окно или нажать ⌘Q, прокси остановится. Чтобы он работал и при закрытом окне, включите работу в фоне.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Включить", color: Theme.warn) { background.enabled = true }
        }
        .card(.warn)
    }

    private var statsLine: some View {
        let s = telegram.stats
        return Text("Соединений: \(s.totalConnections) (сейчас \(s.activeConnections))   ↑ \(bytes(s.bytesUp))   ↓ \(bytes(s.bytesDown))")
            .font(Typo.mono)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    private func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
}
