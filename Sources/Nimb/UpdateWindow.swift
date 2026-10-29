import AppKit
import SwiftUI

/// The window of the update: what is new in the version, and then the installation step by step, so that a failure says where it stopped.
/// Opened from the button at the bottom of the window, from the menu and from the notification, whether or not the main window is open.
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()

    /// Set by the main window (the installation must not start while DNS is being changed).
    weak var dns: DNSViewModel?
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: UpdateWindowView(close: { [weak self] in self?.window?.close() },
                                                                  canInstall: { [weak self] in !(self?.dns?.isLocked ?? false) }))
        host.sizingOptions = [.preferredContentSize]
        let created = NSWindow(contentViewController: host)
        created.title = "Обновление Nimb"
        created.styleMask = [.titled, .closable]
        created.titlebarAppearsTransparent = true
        created.isReleasedWhenClosed = false
        created.appearance = NSAppearance(named: .darkAqua)
        created.backgroundColor = .black
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }
}

/// The window as the program shows it: it follows the model of the updates.
struct UpdateWindowView: View {
    @ObservedObject private var updates = UpdateViewModel.shared
    let close: () -> Void
    let canInstall: () -> Bool

    var body: some View {
        let offered: Release? = { if case .available(let release) = updates.state { return release } else { return updates.offered } }()
        UpdateWindowContent(state: updates.state, progress: updates.progress, release: offered, canInstall: canInstall(),
                            install: { if let offered { updates.install(offered) } }, close: close)
    }
}

/// What the window shows for a state, with nothing in it that moves by itself: the same view is drawn for a picture in the tests.
struct UpdateWindowContent: View {
    let state: UpdateViewModel.State
    let progress: UpdateProgress
    let release: Release?
    let canInstall: Bool
    let install: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            buttons
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(Theme.base)
        .preferredColorScheme(.dark)
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(release.map { "Nimb \($0.version)" } ?? "Nimb")
                .font(.system(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            Text("Сейчас стоит \(Updater.currentVersion)")
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .installing, .failed:
            steps
        case .available(let release):
            whatsNew(release)
        default:
            Text(state == .checking ? "Проверяю обновления…" : "Установлена последняя версия.")
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func whatsNew(_ release: Release) -> some View {
        let items = Updater.whatsNew(in: release.notes)
        return VStack(alignment: .leading, spacing: 10) {
            Text("ЧТО НОВОГО")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textSecondary)
            if items.isEmpty {
                Text("Описание этого релиза смотрите на его странице.")
                    .font(Typo.body)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6).offset(y: -1)
                        Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(UpdateStage.allCases, id: \.self) { stage in
                HStack(spacing: 12) {
                    icon(for: progress.state(of: stage))
                        .frame(width: 20, height: 20)
                    Text(stage.title)
                        .font(.system(size: 14))
                        .foregroundStyle(progress.state(of: stage) == .pending ? Theme.textSecondary : Theme.textPrimary)
                    Spacer()
                }
            }
            if let failure = progress.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Остановилось на этапе «\(failure.stage.title)»")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.bad)
                    Text(failure.message)
                        .font(Typo.small)
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bad.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.bad.opacity(0.4), lineWidth: 1))
                .padding(.top, 4)
            } else {
                Text("Окно можно не трогать: Nimb перезапустится сам.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: UpdateStageState) -> some View {
        switch state {
        case .pending: Circle().stroke(Theme.textSecondary.opacity(0.5), lineWidth: 1.5).frame(width: 14, height: 14)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.system(size: 17))
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad).font(.system(size: 17))
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if let release {
                Button { NSWorkspace.shared.open(release.pageURL) } label: {
                    Text("Страница релиза").font(Typo.small).foregroundStyle(Theme.textSecondary).underline()
                }
                .buttonStyle(.plain)
            }
            Spacer()
            switch state {
            case .available(let release):
                OutlineButton(title: "Позже", color: Theme.textPrimary, action: close)
                installButton("Обновить", action: install)
            case .failed:
                OutlineButton(title: "Скопировать", color: Theme.textPrimary, action: copyDetails)
                    .help("Скопировать подробности ошибки: версии, систему, этап и текст")
                if release != nil { installButton("Повторить", action: install) }
            case .installing:
                EmptyView()
            default:
                OutlineButton(title: "Закрыть", color: Theme.textPrimary, action: close)
            }
        }
    }

    private func installButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.92)))
        }
        .buttonStyle(PressableStyle())
        .disabled(!canInstall)
        .opacity(canInstall ? 1 : 0.45)
    }

    /// What goes to the developer by hand: the versions, the system, the stage and the words of the error.
    private func copyDetails() {
        guard let failure = progress.failure else { return }
        let text = """
        Nimb \(Updater.currentVersion) → \(release?.version ?? "?")
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Этап: \(failure.stage.title)
        Ошибка: \(failure.message)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
