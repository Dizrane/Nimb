import AppKit
import SwiftUI

/// Opens the window «Сообщить о проблеме» from the settings and from the menu of the menu bar.
@MainActor
final class ReportCenter: ObservableObject {
    static let shared = ReportCenter()
    @Published var isShown = false
}

/// The window where a person describes a problem and sends the report: what will be sent is shown, with nothing that names them.
struct ReportSheet: View {
    @EnvironmentObject private var dns: DNSViewModel
    @EnvironmentObject private var telegram: TelegramProxyModel
    @EnvironmentObject private var warp: WarpTunnelModel
    @ObservedObject private var center = ReportCenter.shared

    @StateObject private var description = TextBox()
    @StateObject private var contact = TextBox()
    @StateObject private var details = Flag()
    @StateObject private var state = ReportState()

    private var stage: ReportState.Stage { state.stage }
    private var facts: String { state.facts }
    private var id: String { state.id }

    private var fullText: String {
        DiagnosticReport.head(id: id, description: description.text, contact: contact.text) + "\n\n" + facts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сообщить о проблеме")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)

            if stage == .sent {
                sentView
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.base)
        .preferredColorScheme(.dark)
        .task {
            state.facts = await DiagnosticReport.collect(dns: dns, telegram: telegram, warp: warp)
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Что случилось?").font(Typo.name).foregroundStyle(Theme.textPrimary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description.text)
                        .accessibilityLabel("Что случилось")
                        .font(Typo.body)
                        .scrollContentBackground(.hidden)
                        // The text starts where the placeholder does: 10 pt from the left (5 here and 5 of the text view), 8 pt from the top.
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    if description.text.isEmpty {
                        Text("Что вы делали и что пошло не так. Можно в двух словах.")
                            .font(Typo.body)
                            // The same grey as the placeholder of the field below, which the system draws.
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Как вам ответить (по желанию)").font(Typo.name).foregroundStyle(Theme.textPrimary)
                TextField("@имя в Telegram или почта", text: $contact.text)
                    .accessibilityLabel("Как вам ответить, по желанию")
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Button { details.value.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("Посмотреть, что будет отправлено")
                            .font(Typo.small)
                        Image(systemName: "arrow.up.forward.square").accessibilityHidden(true)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $details.value, arrowEdge: .bottom) {
                    ScrollView {
                        Text(facts.isEmpty ? "Собираю…" : fullText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(width: 460, height: 340)
                }
                Text("Версия, состояние сервисов и последние строки журнала. Паролей, ключей и ваших личных данных (адрес, адреса вашей сети, имя компьютера) в отчёте нет; адреса серверов провайдеров есть, они помогают найти ошибку.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.askedToPaste {
                Text("Отчёт скопирован. В открывшемся личном чате с разработчиком нажмите ⌘V и отправьте его.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let message) = stage {
                Text("\(message) Нажмите «Написать разработчику»: откроется личный чат с разработчиком, отчёт будет скопирован, останется вставить его и отправить.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !ReportConfig.canSend {
                Text("Отправка из приложения не настроена. Нажмите «Написать разработчику»: откроется личный чат с разработчиком, отчёт будет скопирован.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                OutlineButton(title: "Отмена", color: Theme.textSecondary) { close() }
                OutlineButton(title: "Скопировать", color: Theme.textPrimary, action: copy)
                    .disabled(facts.isEmpty)
                if !ReportConfig.canSend || failed {
                    OutlineButton(title: "Написать разработчику", color: Theme.textPrimary, action: writeToDeveloper)
                        .disabled(facts.isEmpty)
                }
                Button(action: send) {
                    HStack(spacing: 7) {
                        if stage == .sending { ProgressView().controlSize(.small).tint(.black) }
                        Text(stage == .sending ? "Отправляю…" : "Отправить")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(PressableStyle())
                .disabled(facts.isEmpty || stage == .sending || !ReportConfig.canSend)
                .opacity(facts.isEmpty || !ReportConfig.canSend ? 0.5 : 1)
            }
        }
    }

    private var sentView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").accessibilityHidden(true).foregroundStyle(Theme.ok)
                Text("Отчёт отправлен").font(Typo.name).foregroundStyle(Theme.textPrimary)
            }
            Text("Номер \(id). Спасибо, это помогает исправить ошибку.")
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                OutlineButton(title: "Закрыть", color: Theme.textPrimary) { close() }
            }
        }
    }

    // MARK: Actions

    private func send() {
        state.stage = .sending
        let text = fullText, id = id
        AppLog.shared.add("report", "отправляю отчёт \(id)")
        Task {
            do {
                try await ReportSender.send(id: id, text: text)
                AppLog.shared.add("report", "отчёт \(id) отправлен")
                state.stage = .sent
            } catch {
                AppLog.shared.add("report", "отчёт \(id) не отправлен: \(error.localizedDescription)")
                state.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
    }

    /// The report goes to the clipboard (cut to one message) and a chat with the developer is opened: Telegram if it is installed.
    private func writeToDeveloper() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticReport.fitted(fullText, limit: ReportConfig.messageLimit), forType: .string)
        let app = URL(string: "tg://resolve?domain=\(ReportConfig.developerHandle)")
        let web = URL(string: "https://t.me/\(ReportConfig.developerHandle)")
        if let app, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let web {
            NSWorkspace.shared.open(web)
        }
        AppLog.shared.add("report", "отчёт \(id) скопирован для чата с разработчиком")
        state.askedToPaste = true
    }

    private var failed: Bool { if case .failed = stage { return true } else { return false } }

    private func close() { center.isShown = false }
}

/// What the window keeps while it is open. Stands in for @State, whose macro plugin is not shipped with Command Line Tools.
final class ReportState: ObservableObject {
    enum Stage: Equatable {
        case writing
        case sending
        case sent
        case failed(String)
    }

    @Published var stage = Stage.writing
    @Published var facts = ""
    /// The report is on the clipboard and the chat with the developer is open.
    @Published var askedToPaste = false
    let id = DiagnosticReport.newID()
}

/// A text the sheet owns. Stands in for @State, whose macro plugin is not shipped with Command Line Tools.
final class TextBox: ObservableObject {
    @Published var text = ""
}
