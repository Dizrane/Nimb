import SwiftUI

/// When the proxy of Telegram is told to try the tunnel: some providers let only a part of the servers of Telegram through (the rest, where
/// some files and pictures are kept, open only through the tunnel). The proxy works alone; this is only advice, and it goes away as soon as
/// the tunnel is on or the errors stop.
enum TelegramTunnelAdvice {
    /// How long without a new failure before the advice is withdrawn.
    static let quiet: TimeInterval = 600

    static func shows(failures: Int, failuresRecently: Bool, tunnelIsOff: Bool) -> Bool {
        tunnelIsOff && failuresRecently && failures >= 5
    }
}

/// The Telegram page: one switch for the proxy, one button that connects Telegram Desktop to it.
struct TelegramPage: View {
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject var warp: WarpTunnelModel
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
                        if TelegramTunnelAdvice.shows(failures: telegram.stats.failures, failuresRecently: telegram.failuresRecently, tunnelIsOff: warp.phase == .off) {
                            tunnelAdvice
                        }
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

    private var tunnelAdvice: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Часть файлов Telegram лежит на серверах, до которых ваша сеть не достаёт: прокси сам с этим не справится. Туннель «YouTube и Discord» их откроет.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Включить туннель", color: Theme.textPrimary) { warp.connect() }
        }
        .card()
    }

    /// Without it, quitting (Command-Q) switches the proxy off, and Telegram stops working. Closing the window does not.
    private var backgroundHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Выйдете из Nimb (⌘Q), и прокси остановится. Включите работу в фоне: тогда ⌘Q только закроет окно.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Включить", color: Theme.textPrimary) { background.enabled = true }
        }
        .card()
    }

}
