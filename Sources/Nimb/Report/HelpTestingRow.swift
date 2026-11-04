import SwiftUI

/// The second line of the card «Сообщить о проблеме»: the switch «Помогать тестированию», and what it is.
struct HelpTestingRow: View {
    @ObservedObject private var reporter = AutoReporter.shared
    @StateObject private var info = Flag()

    private func detail(modified: Bool) -> String {
        if let paused = ReportGate.shortWords(modified: modified) { return paused }
        guard reporter.enabled else { return "Сводка раз в сутки." }
        guard let last = reporter.lastSent else { return "Пока ничего не отправлено." }
        return "Отправлено: \(reporter.sentCount), последний \(AutoReporter.lastWords(last))."
    }

    var body: some View {
        // A changed build sends nothing (see `BuildCheck`), so the switch is off and cannot be turned on: it would be an empty promise.
        let modified = BuildCheck.problem != nil
        return HStack(spacing: Space.m) {
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
                Text(detail(modified: modified))
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            PillSwitch(label: "Помогать тестированию", isOn: reporter.enabled && !modified, disabled: modified) { reporter.setEnabled(!reporter.enabled) }
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
            point("Что уходит", "Раз в сутки одна сводка: цифры за день и серьёзные сбои (неожиданное закрытие, остановка туннеля или сервиса дольше 10 минут, неудачное обновление) со временем и состоянием. Сайт, который просто не открылся, сбоем не считается.")
            point("Когда", "Один отчёт в сутки, больше ничего не отправляется. Без сети отчёт уйдёт позже. Принимаются отчёты только последней версии Nimb.")
            point("Что внутри", "Как в «Сообщить о проблеме»: версии, состояние сервисов, журнал. Паролей и личных данных нет. Адреса серверов DNS и туннеля есть.")
            point("Номер установки", "Случайный, с вами не связан. Стирается, когда выключаете переключатель.")
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
