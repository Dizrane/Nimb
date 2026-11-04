import SwiftUI

/// When the proxy of Telegram is told to try the tunnel: some providers let only a part of the servers of Telegram through (the rest, where
/// some files and pictures are kept, open only through the tunnel), and some let none through (then not a single connection of the proxy
/// gets to Telegram, and it is said at once). The proxy works alone; this is only advice, and it goes away as soon as the tunnel is on or
/// the errors stop.
enum TelegramTunnelAdvice {
    /// How long without a new failure before the advice is withdrawn.
    static let quiet: TimeInterval = 600

    enum Kind: Equatable { case blocked, partly }

    /// `reached` is the number of connections that got to Telegram (by the WebSocket or directly) since the proxy was started.
    static func kind(failures: Int, reached: Int, failuresRecently: Bool, tunnelIsOff: Bool) -> Kind? {
        guard tunnelIsOff, failuresRecently else { return nil }
        if reached == 0 && failures >= 2 { return .blocked }
        return failures >= 5 ? .partly : nil
    }

    static func words(_ kind: Kind) -> String {
        switch kind {
        case .blocked: return "Сеть не пускает к серверам Telegram. Поможет туннель «YouTube и Discord»."
        case .partly: return "Часть файлов Telegram лежит на серверах, недоступных в вашей сети. Поможет туннель «YouTube и Discord»."
        }
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
                    ? "Прокси работает."
                    : "Включите, чтобы Telegram открывался.",
                accessibility: telegram.isRunning ? "Остановить прокси для Telegram" : "Включить прокси для Telegram",
                disabled: telegram.isStarting,
                action: telegram.toggle
            )
        } right: {
            VStack(spacing: Space.gap) {
                    if telegram.isRunning {
                        connectCard
                        if !background.enabled { backgroundHint }
                        if let kind = TelegramTunnelAdvice.kind(failures: telegram.stats.failures, reached: telegram.stats.webSocket + telegram.stats.directTCP,
                                                                failuresRecently: telegram.failuresRecently, tunnelIsOff: warp.phase == .off) {
                            tunnelAdvice(kind)
                        }
                        if telegram.wrongSecretRecently {
                            NoticeCard(lines: ["Telegram подключается с чужим ключом: на этом порту указан другой прокси. Нажмите «Открыть в Telegram», старый прокси удалите."], color: Theme.warn, symbol: "exclamationmark.triangle")
                        }
                    } else {
                        InfoCard(
                            title: "Как это работает",
                            text: "Включите прокси и подтвердите «Добавить прокси» в Telegram."
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
            Text("В Telegram откроется «Добавить прокси»: подтвердите.")
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

    private func tunnelAdvice(_ kind: TelegramTunnelAdvice.Kind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(TelegramTunnelAdvice.words(kind))
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
            Text("После выхода из Nimb (⌘Q) прокси остановится. «Работать в фоне» оставит его работать.")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OutlineButton(title: "Включить", color: Theme.textPrimary) { background.enabled = true }
        }
        .card()
    }

}
