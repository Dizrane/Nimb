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

/// What the switch does, in a few short points; the report as it would go now is on the same popover, in place of the points (one thing to
/// read at a time, and only one place that scrolls: the report itself).
private struct HelpTestingInfo: View {
    @StateObject private var preview = PreviewText()
    @StateObject private var showsExample = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsExample.value { example } else { explanation }
        }
        .infoPanel(width: 440)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Помогать тестированию").font(Typo.name)
            point("Когда", "Сразу, если что-то серьёзно сломалось: программа закрылась неожиданно, туннель остановился сам или молчит больше 10 минут, сервис не работает как надо больше 10 минут, обновление не проверяется или не ставится. Если сайт просто не открылся, это не причина: такое бывает у всех.")
            point("Как часто", "О сбоях не чаще одного отчёта в час и пяти в сутки. Раз в сутки приходит одна сводка с цифрами за день. Если сети нет, отчёт ждёт до суток и уходит сам.")
            point("Что внутри", "То же, что в «Сообщить о проблеме»: версии, состояние сервисов, журнал. Паролей, ключей и личных данных (адрес, имя компьютера, адреса вашей сети) нет. Адреса серверов DNS и туннеля есть: они помогают найти ошибку.")
            point("Номер установки", "Случайный. По нему отчёты с одного Mac связываются между собой, но не с вами лично. Когда вы выключаете переключатель, он стирается.")
            Divider()
            OutlineButton(title: "Показать пример отчёта", color: Theme.textPrimary) {
                if preview.text == nil { preview.load() }
                showsExample.value = true
            }
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { showsExample.value = false } label: {
                    Label("Назад", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text("Так выглядит отчёт сейчас").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(preview.text ?? "Собираю…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
