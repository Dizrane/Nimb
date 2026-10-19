import SwiftUI

/// The main page, for everyday use once everything is set up: one button for all three, and a switch for each.
/// The other pages are for setting a single thing up again.
struct HomePage: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject var warp: WarpTunnelModel
    @ObservedObject private var all = AllServices.shared

    private var aiOn: Bool { model.active != nil }
    private var warpAvailable: Bool { warp.phase != .unavailable }
    private var onCount: Int { [aiOn, telegram.isRunning, warp.isOn].filter { $0 }.count }
    private var allOn: Bool { onCount == (warpAvailable ? 3 : 2) }
    private var busy: Bool { all.isRunning || model.isLocked || telegram.isStarting || warp.isWorking }

    private var title: String {
        if busy { return "Подождите" }
        if allOn { return "Всё включено" }
        return onCount == 0 ? "Выключено" : "Включено частично"
    }

    private var subtitle: String {
        if busy { return model.isLocked || warp.isWorking ? "Подтвердите пароль администратора, если macOS попросит" : "" }
        if allOn { return "Нейросети, Telegram, YouTube и Discord работают." }
        return onCount == 0 ? "Одна кнопка включает нейросети, Telegram, YouTube и Discord." : "Включите остальное кнопкой или переключателями ниже."
    }

    var body: some View {
        VStack(spacing: 0) {
            MascotHero(
                art: .power,
                isOn: allOn,
                isBusy: busy,
                halos: all.effectiveCount,
                title: title,
                subtitle: subtitle,
                accessibility: allOn ? "Выключить всё" : "Включить всё",
                disabled: busy,
                action: allOn ? all.disableAll : all.enableAll
            )

            FitOrScroll {
                VStack(spacing: Space.gap) {
                    FeatureRow(
                        kind: .ai, title: "Нейросети",
                        detail: aiOn ? (model.active?.name ?? "Включено") : "ChatGPT, Claude, Gemini и другие",
                        isOn: aiOn, pending: model.isBusy || model.isProbing || model.isSettingUp, disabled: busy,
                        set: { _ in model.toggle() }
                    )
                    FeatureRow(
                        kind: .telegram, title: "Telegram",
                        detail: telegram.isRunning ? "Прокси работает" : "Прокси для Telegram Desktop",
                        isOn: telegram.isRunning, pending: telegram.isStarting, disabled: busy,
                        set: { _ in telegram.toggle() }
                    )
                    FeatureRow(
                        kind: .media, title: "YouTube и Discord",
                        detail: warp.isOn ? "Туннель работает" : (warpAvailable ? "Туннель WARP" : "Недоступно в этой сборке"),
                        isOn: warp.isOn, pending: warp.isWorking, disabled: busy || !warpAvailable,
                        set: { _ in all.toggleWarp() }
                    )
                    ForEach([model.errorMessage, telegram.errorMessage, warp.errorMessage].compactMap { $0 }, id: \.self) { message in
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                }
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.s)
            }
        }
    }
}

/// One thing Nimb does, with its switch.
private struct FeatureRow: View {
    let kind: StepIconKind
    let title: String
    let detail: String
    let isOn: Bool
    /// The service is being switched: a small spinner takes the place of the switch until the state is final.
    var pending = false
    let disabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            StepIcon(player: StepIconPlayers.shared.player(kind), size: 38, dimmed: !isOn)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if pending {
                ProgressView().controlSize(.small).frame(width: 38)
            } else {
                Toggle(title, isOn: Binding(get: { isOn }, set: set))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.ok)
                    .disabled(disabled)
            }
        }
        .card()
        .opacity(disabled && !isOn ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
