import SwiftUI

/// The second line of the card «Сообщить о проблеме»: the switch «Помогать тестированию», and what it is.
struct HelpTestingRow: View {
    @ObservedObject private var reporter = AutoReporter.shared
    @StateObject private var info = Flag()

    private var detail: String {
        guard reporter.enabled else { return "Сам отправит отчёт, если что-то пойдёт не так." }
        guard let last = reporter.lastSent else { return "Включено. Пока ничего не отправлено." }
        return "Отправлено: \(reporter.sentCount), последний \(AutoReporter.lastWords(last))."
    }

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Помогать тестированию")
                        .font(Typo.name)
                        .foregroundStyle(Theme.textPrimary)
                    Button { info.value.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Что это и что отправляется")
                    .accessibilityLabel("Что такое «Помогать тестированию»")
                    .popover(isPresented: $info.value, arrowEdge: .trailing) { HelpTestingInfo() }
                }
                Text(detail)
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            PillSwitch(label: "Помогать тестированию", isOn: reporter.enabled) { reporter.setEnabled(!reporter.enabled) }
        }
    }
}

/// What the switch does, in words, and a report as it would go now.
private struct HelpTestingInfo: View {
    @StateObject private var preview = PreviewText()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Помогать тестированию")
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            point("Когда", "Сразу уходит отчёт, если сломалось что-то серьёзное: программа закрылась неожиданно, туннель остановился сам, сервис работает не так, как должен, больше 10 минут, включение или выключение закончилось ошибкой, проверка обновлений не удаётся несколько раз подряд. Если сайт или сервис просто не открылся, это не причина: такое бывает у всех.")
            point("Как часто", "О сбоях: не чаще одного отчёта в час и пяти в сутки, одно и то же не чаще раза в 6 часов. И раз в сутки одна сводка: цифры за день, чтобы видеть мелочи, которые не стоят отдельного отчёта.")
            point("Что внутри", "То же, что в «Сообщить о проблеме»: версии, состояние сервисов, журнал и состояние раз в 5 минут за сутки. Паролей, ключей и ваших личных данных (адрес, адреса вашей сети, имя компьютера) нет. Адреса серверов провайдеров есть: они помогают найти ошибку.")
            point("Номер установки", "Случайный, чтобы отличить повторы с одного компьютера. Когда вы выключаете переключатель, он стирается.")
            Divider().overlay(Color.white.opacity(0.1))
            if let text = preview.text {
                Text("Так выглядит отчёт сейчас")
                    .font(Typo.small).foregroundStyle(Theme.textSecondary)
                ScrollView {
                    Text(text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            } else {
                OutlineButton(title: preview.loading ? "Собираю…" : "Показать пример отчёта", color: Theme.textPrimary) { preview.load() }
                    .disabled(preview.loading)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Theme.base)
        .preferredColorScheme(.dark)
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(text).font(Typo.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private final class PreviewText: ObservableObject {
    @Published var text: String?
    @Published var loading = false

    func load() {
        loading = true
        Task {
            text = await AutoReporter.shared.preview()
            loading = false
        }
    }
}
