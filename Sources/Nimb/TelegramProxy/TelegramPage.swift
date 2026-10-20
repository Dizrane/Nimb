import SwiftUI

/// The Telegram page: one switch for the proxy, one button that connects Telegram Desktop to it.
struct TelegramPage: View {
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject private var background = BackgroundMode.shared

    var body: some View {
        TwoColumns {
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
        } right: {
            VStack(spacing: Space.gap) {
                    if telegram.isRunning {
                        connectCard
                        if !background.enabled { backgroundHint }
                        if telegram.wrongSecretRecently {
                            NoticeCard(lines: ["Telegram подключается с чужим ключом: в нём, похоже, указан другой прокси на этом порту. Нажмите «Открыть в Telegram» и подтвердите, а старый прокси удалите."], color: Theme.warn, symbol: "exclamationmark.triangle")
                        }
                    } else {
                        InfoCard(
                            title: "Как это работает",
                            text: "Включите прокси и подтвердите окно «Добавить прокси» в Telegram."
                        )
                    }
                    if let message = telegram.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
            }
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Подключить Telegram")
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text("Откроется окно «Добавить прокси» в Telegram Desktop: подтвердите его.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                OutlineButton(title: "Скопировать ссылку", color: Theme.textPrimary, action: telegram.copyLink)
                OutlineButton(title: "Открыть в Telegram", color: Theme.textPrimary, action: telegram.openInTelegram)
            }
        }
        .card()
    }

    /// Without it, closing the window or pressing Command-Q switches the proxy off, and Telegram stops working.
    private var backgroundHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Закроете окно, и прокси остановится. Включите работу в фоне.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Включить", color: Theme.textPrimary) { background.enabled = true }
        }
        .card()
    }

}
