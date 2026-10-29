import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var telegram: TelegramProxyModel
    @ObservedObject var warp: WarpTunnelModel
    @ObservedObject var onboarding: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if onboarding.step > 0 && onboarding.step < Onboarding.lastStep {
                    Button(action: onboarding.finish) {
                        Text("Закрыть")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .frame(height: 70)

            // The step sits in the middle of the free height. It is tried in its usual size, then compact (a smaller picture, closer lines), and
            // only a step that does not fit even so scrolls (a large system text, a long message of an error).
            ViewThatFits(in: .vertical) {
                column(compact: false)
                column(compact: true)
                ScrollView { column(compact: true) }.scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func column(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            Dots(count: Onboarding.lastStep + 1, current: onboarding.step)
                .padding(.bottom, compact ? 2 : 6)
            content
                .id(onboarding.step)
                .transition(.opacity)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .environment(\.compactStep, compact)
    }

    @ViewBuilder
    var content: some View {
        switch onboarding.step {
        case 0: welcome
        case 1: aiStep
        case 2: telegramStep
        case 3: mediaStep
        default: backgroundStep
        }
    }

    // MARK: Steps

    private var welcome: some View {
        StepFrame(
            kind: .welcome,
            title: "Добро пожаловать в Nimb",
            text: "За пару минут настроим всё, чтобы работали нейросети, Telegram, YouTube и Discord. Ничего устанавливать и вводить не нужно: Nimb делает всё сам. Когда понадобится пароль от вашего Mac, он попросит его в окне macOS: оно может называться «osascript», так система подписывает запрос Nimb."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Bullet("Нейросети: ChatGPT, Claude, Gemini и другие")
                Bullet("Telegram: быстрее и без блокировок")
                Bullet("YouTube и Discord")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            PrimaryButton(title: "Начать", action: onboarding.next)
            SkipButton(title: "Настрою потом", action: onboarding.finish)
        }
    }

    private var aiStep: some View {
        let done = model.active != nil
        return StepFrame(
            kind: .ai,
            title: "Нейросети",
            text: "Из-за региона ChatGPT, Claude и другие нейросети могут не открываться. Nimb переключит DNS на специальный сервис, и они заработают. Лучший сервис он подберёт сам."
        ) {
            if done {
                DoneRow(text: "Включено: \(model.active?.name ?? "")")
                PrimaryButton(title: "Далее", action: onboarding.next)
            } else if model.isLocked {
                BusyRow(text: model.isProbing ? model.probeProgress : "Подтвердите пароль администратора…")
            } else {
                PrimaryButton(title: "Подобрать и включить") { model.enableBest() }
                SkipButton(title: "Пропустить", action: onboarding.next)
            }
            if let message = model.errorMessage {
                NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
            }
        }
    }

    private var telegramStep: some View {
        StepFrame(
            kind: .telegram,
            title: "Telegram",
            text: "Nimb запустит на этом Mac небольшой прокси, а Telegram будет ходить через него. После включения нажмите «Открыть в Telegram» и подтвердите окно «Добавить прокси»."
        ) {
            if telegram.isRunning {
                DoneRow(text: "Прокси работает")
                OutlineButton(title: "Открыть в Telegram", color: Theme.textPrimary, action: telegram.openInTelegram)
                PrimaryButton(title: "Далее", action: onboarding.next)
            } else if telegram.isStarting {
                BusyRow(text: "Запускаю…")
            } else {
                PrimaryButton(title: "Включить прокси", action: telegram.start)
                SkipButton(title: "Пропустить", action: onboarding.next)
            }
            if let message = telegram.errorMessage {
                NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
            }
        }
    }

    private var mediaStep: some View {
        StepFrame(
            kind: .media,
            title: "YouTube и Discord",
            text: "Nimb создаст для этого Mac собственный анонимный аккаунт Cloudflare WARP и включит туннель. Личных данных он не передаёт. Пока туннель включён, через Cloudflare идёт весь трафик Mac: если не открывается банк или Госуслуги, выключите его. Понадобится пароль от Mac."
        ) {
            if warp.isOn {
                DoneRow(text: "Туннель работает")
                PrimaryButton(title: "Далее", action: onboarding.next)
            } else if warp.isWorking {
                if case .working(let text) = warp.phase { BusyRow(text: text) }
            } else if warp.phase == .unavailable {
                Text("В этой сборке Nimb нет туннеля, шаг пропускается.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                PrimaryButton(title: "Далее", action: onboarding.next)
            } else {
                PrimaryButton(title: "Включить") { warp.phase == .notInstalled ? warp.enable() : warp.connect() }
                Text("Включая, вы принимаете условия Cloudflare WARP.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                Link("Условия Cloudflare WARP", destination: WarpTerms.url)
                    .font(Typo.small)
                SkipButton(title: "Пропустить", action: onboarding.next)
            }
            if let message = warp.errorMessage {
                NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
            }
        }
    }

    private var backgroundStep: some View {
        StepFrame(
            kind: .gear,
            title: "Чтобы работало само",
            text: "Рекомендуем включить всё: Nimb запустится с Mac, будет работать при закрытом окне и скажет о новой версии."
        ) {
            // The three switches are one card with three rows, not three cards: the step has to fit the smallest window.
            VStack(spacing: 0) {
                BackgroundCard(framed: false)
                Divider().overlay(Color.white.opacity(0.08))
                LaunchAtLoginCard(framed: false)
                Divider().overlay(Color.white.opacity(0.08))
                NotificationsCard(framed: false, showsTest: false)
            }
            .card(.neutral)
            PrimaryButton(title: "Готово", action: onboarding.finish)
            Text("Пройти настройку заново можно в «Настройках» (внизу слева).")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Pieces

private struct CompactStepKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when a step of the first set-up is drawn smaller to fit a low window.
    fileprivate var compactStep: Bool {
        get { self[CompactStepKey.self] }
        set { self[CompactStepKey.self] = newValue }
    }
}

private struct StepFrame<Content: View>: View {
    @Environment(\.compactStep) private var compact
    let kind: StepIconKind
    let title: String
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            StepIcon(player: StepIconPlayers.shared.player(kind), size: compact ? 56 : 80, halo: true)
                .padding(.top, compact ? 0 : 4)
            Text(title)
                .font(Typo.status)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .lineLimit(2)
            Text(text)
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == current ? 0.9 : index < current ? 0.45 : 0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(current + 1) из \(count)")
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark").accessibilityHidden(true)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 3)
            Text(text)
                .font(Typo.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct DoneRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").accessibilityHidden(true).foregroundStyle(Theme.ok)
            Text(text).font(Typo.name).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct BusyRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Typo.small).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }
}

/// The one button of a step: wide, light, impossible to miss.
private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.92)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct SkipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
