import SwiftUI

/// The main page, for everyday use once everything is set up: one button for all three, and a switch for each.
/// The other pages are for setting a single thing up again.
struct HomePage: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject var warp: WarpTunnelModel
    /// True while "all at once" walks through the three; each may ask for the password in turn.
    @StateObject private var batch = Flag()

    private var aiOn: Bool { model.active != nil }
    private var warpAvailable: Bool { warp.phase != .unavailable }
    private var onCount: Int { [aiOn, telegram.isRunning, warp.isOn].filter { $0 }.count }
    private var allOn: Bool { onCount == (warpAvailable ? 3 : 2) }
    private var busy: Bool { batch.value || model.isLocked || telegram.isStarting || warp.isWorking }

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
                level: Double(onCount) / Double(warpAvailable ? 3 : 2),
                title: title,
                subtitle: subtitle,
                accessibility: allOn ? "Выключить всё" : "Включить всё",
                disabled: busy,
                action: allOn ? disableAll : enableAll
            )

            ScrollView {
                VStack(spacing: 10) {
                    FeatureRow(
                        symbol: "sparkles", title: "Нейросети",
                        detail: aiOn ? (model.active?.name ?? "Включено") : "ChatGPT, Claude, Gemini и другие",
                        isOn: aiOn, disabled: busy,
                        set: { _ in model.toggle() }
                    )
                    FeatureRow(
                        symbol: "paperplane", title: "Telegram",
                        detail: telegram.isRunning ? "Прокси работает" : "Прокси для Telegram Desktop",
                        isOn: telegram.isRunning, disabled: busy,
                        set: { _ in telegram.toggle() }
                    )
                    FeatureRow(
                        symbol: "play.rectangle", title: "YouTube и Discord",
                        detail: warp.isOn ? "Туннель работает" : (warpAvailable ? "Туннель WARP" : "Недоступно в этой сборке"),
                        isOn: warp.isOn, disabled: busy || !warpAvailable,
                        set: { _ in toggleWarp() }
                    )
                    ForEach([model.errorMessage, telegram.errorMessage, warp.errorMessage].compactMap { $0 }, id: \.self) { message in
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                    Text("Выключайте то, что не нужно: выключенное ничего не расходует. Настроить каждый пункт заново можно на вкладках выше.")
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

    // MARK: Actions

    private func toggleWarp() {
        if warp.isOn { warp.disconnect() } else if warp.phase == .notInstalled { warp.enable() } else { warp.connect() }
    }

    /// Waits until the previous change is over, so that the password prompts come one after another.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        while model.isLocked || warp.isWorking || telegram.isStarting {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func enableAll() {
        guard !busy else { return }
        batch.value = true
        Task {
            if !telegram.isRunning { telegram.start(); await settle() }
            if model.active == nil { model.toggle(); await settle() }
            if warpAvailable && !warp.isOn { toggleWarp(); await settle() }
            batch.value = false
        }
    }

    private func disableAll() {
        guard !busy else { return }
        batch.value = true
        Task {
            if telegram.isRunning { telegram.stop() }
            if model.active != nil { model.toggle(); await settle() }
            if warp.isOn { warp.disconnect(); await settle() }
            batch.value = false
        }
    }
}

/// One thing Nimb does, with its switch.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Bool
    let disabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(isOn ? Theme.ok : Theme.textSecondary)
                .frame(width: 26)
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
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.ok)
                .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: isOn ? Theme.ok : .white, tintOpacity: isOn ? 0.04 : 0, borderOpacity: isOn ? 0.32 : 0.14)
        .opacity(disabled && !isOn ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
