import AppKit
import SwiftUI

/// The window of the update: what is new in the version, and then the installation step by step, so that a failure says where it stopped.
/// Opened from the button at the bottom of the window, from the menu and from the notification, whether or not the main window is open.
@MainActor
final class UpdateWindowController: NSObject, NSWindowDelegate {
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
        // The content goes under the title bar, and draws a black strip of its own there (see `titleStrip`): the buttons of the window sit on it,
        // not on the glass, and it is of the same black as the rest of the window, not the grey of the system.
        created.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.isReleasedWhenClosed = false
        created.appearance = NSAppearance(named: .darkAqua)
        // The glass is drawn by the window's content (see `GlassBackground`), so the window itself shows through below the title bar.
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        // Always above the main window of Nimb, so that it is not left behind it; it goes away with the program when Nimb is not the program
        // in front (a failure brings it back: `show()` makes the program the one in front).
        created.level = .floating
        created.hidesOnDeactivate = true
        created.delegate = self
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    /// While the update is being installed the window only hides: the installation goes on, and the window comes back by itself if it fails.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if case .installing = UpdateViewModel.shared.state {
            sender.orderOut(nil)
            return false
        }
        return true
    }
}

/// Black matte glass: the blurred picture of what is behind the window, darkened so that it does not shine.
private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .id(phaseKey)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
            buttons
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: phaseKey)
        .padding(EdgeInsets(top: Self.titleStripHeight + 22, leading: 26, bottom: 24, trailing: 26))
        .frame(width: 470, alignment: .leading)
        .background {
            ZStack {
                GlassBackground()
                Color.black.opacity(0.58)
            }
        }
        .overlay(alignment: .top) { titleStrip }
        .preferredColorScheme(.dark)
    }

    private static let titleStripHeight: CGFloat = 28

    /// The strip at the top, under the buttons of the window: nearly opaque black with a thin line below it.
    private var titleStrip: some View {
        Rectangle()
            .fill(Color.black.opacity(0.9))
            .frame(height: Self.titleStripHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    /// What the window is showing now: a change of it is a change of the picture, and it fades.
    private var phaseKey: String {
        switch state {
        case .available: "available"
        case .installing, .failed: "steps"
        default: "idle"
        }
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
                // A short list is shown whole; a long one scrolls inside a place of a fixed height, so the window never grows big.
                ViewThatFits(in: .vertical) {
                    notesList(items)
                    ScrollView(.vertical) { notesList(items) }
                }
                .frame(maxHeight: 250)
            }
        }
    }

    private func notesList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

    /// «Загрузка · 4,5 из 10,7 МБ» while the archive comes, otherwise the name of the stage that goes on.
    private var currentLine: String {
        if progress.isRestarting { return "Готово" }
        if progress.failure != nil { return "Остановилось" }
        guard let stage = UpdateStage.allCases.first(where: { progress.state(of: $0) == .running }) else { return "Начинаю…" }
        if stage == .download, progress.total > 0 {
            let format = ByteCountFormatter()
            format.countStyle = .file
            return "Загрузка · \(format.string(fromByteCount: progress.downloaded)) из \(format.string(fromByteCount: progress.total))"
        }
        return stage.title
    }

    /// The line that fills as the installation goes, with the percent at its end.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(currentLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded())) %")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(progress.failure != nil ? Theme.bad : Theme.textPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(progress.failure != nil ? Theme.bad : Theme.ok)
                        .frame(width: max(6, proxy.size.width * progress.fraction))
                        .shadow(color: (progress.failure != nil ? Theme.bad : Theme.ok).opacity(0.5), radius: 5)
                }
            }
            .frame(height: 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress.fraction)
        }
        .padding(.bottom, 6)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar
            ForEach(UpdateStage.allCases, id: \.self) { stage in
                HStack(spacing: 12) {
                    icon(for: progress.state(of: stage))
                        .id(progress.state(of: stage))
                        .transition(reduceMotion ? .identity : .scale(scale: 0.4).combined(with: .opacity))
                        .frame(width: 20, height: 20)
                    Text(stage.title)
                        .font(.system(size: 14))
                        .foregroundStyle(progress.state(of: stage) == .pending ? Theme.textSecondary : Theme.textPrimary)
                    Spacer()
                }
            }
            if progress.isRestarting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Перезапускаю Nimb…")
                        .font(Typo.small)
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.top, 4)
                .transition(.opacity)
            } else if let failure = progress.failure {
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
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
            } else {
                Text("Окно можно закрыть: обновление продолжится само.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82), value: progress)
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
