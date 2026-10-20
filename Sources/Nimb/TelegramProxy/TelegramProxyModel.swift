import AppKit
import SwiftUI

/// The Telegram proxy as the window and the menu see it: on or off, the link, the numbers.
@MainActor
final class TelegramProxyModel: ObservableObject {
    @Published private(set) var isRunning = false { didSet { if isRunning != oldValue { AppLog.shared.add("telegram", isRunning ? "прокси включён, порт \(port)" : "прокси выключен") } } }
    @Published private(set) var isStarting = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var stats = TelegramProxyStats()
    /// Telegram came with another key a moment ago (a proxy of an older install is still saved in it). It is true only while that goes on:
    /// ten seconds without such a connection and the warning goes away, and it comes back if they start again.
    @Published private(set) var wrongSecretRecently = false
    @Published var errorMessage: String? { didSet { if let message = errorMessage { AppLog.shared.add("telegram", "ошибка: \(message)") } } }
    /// Whether the proxy was on when Nimb was last used: it comes back by itself, nobody has to find a switch for it.
    @Published private(set) var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey) }
    }

    private static let secretKey = "telegramProxySecret"
    private static let portKey = "telegramProxyPort"
    private static let autoStartKey = "telegramProxyAutoStart"

    let secretHex: String
    private let engine: TelegramProxyEngine
    private var poller: Task<Void, Never>?
    private var isRecovering = false
    private var wrongSecretWatch = RecentCount(quiet: 10)
    /// Opens the main window again after it has been closed; set by the window itself.
    var openMainWindow: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: Self.secretKey), saved.count == 32 {
            secretHex = saved
        } else {
            secretHex = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(secretHex, forKey: Self.secretKey)
        }
        engine = TelegramProxyEngine(secretHex: secretHex)
        autoStart = defaults.bool(forKey: Self.autoStartKey)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [engine] _ in
            engine.stop()
        }
        // Not inside the first update of the scenes: changing state then makes SwiftUI abort.
        if autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
        }
    }

    /// `tg://proxy` link: Telegram Desktop opens a dialog that adds this proxy.
    var link: String { "tg://proxy?server=127.0.0.1&port=\(port)&secret=dd\(secretHex)" }

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        let saved = UInt16(clamping: UserDefaults.standard.integer(forKey: Self.portKey))
        let preferred = saved >= 1024 ? saved : 1443
        Task {
            do {
                let chosen = try await engine.start(preferredPort: preferred)
                UserDefaults.standard.set(Int(chosen), forKey: Self.portKey)
                port = chosen
                isRunning = true
                autoStart = true
                beginPolling()
            } catch {
                errorMessage = "Не удалось запустить прокси: \(error.localizedDescription)"
            }
            isStarting = false
        }
    }

    func stop() {
        poller?.cancel()
        engine.stop()
        isRunning = false
        autoStart = false
        stats = TelegramProxyStats()
        watchWrongSecret(0, reset: true)
    }

    /// Remembers when the count of connections with another key last grew, and says whether that was just now.
    private func watchWrongSecret(_ count: Int, reset: Bool = false) {
        if reset { wrongSecretWatch.reset() }
        let recent = wrongSecretWatch.observe(count, at: Date())
        if recent != wrongSecretRecently { wrongSecretRecently = recent }
    }

    func toggle() { isRunning ? stop() : start() }

    func openInTelegram() {
        guard isRunning, let url = URL(string: link) else { return }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "Не удалось открыть Telegram. Скопируйте ссылку и отправьте её себе в «Избранное»."
        }
    }

    func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func beginPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.engine.snapshot
                if snapshot != self.stats { self.stats = snapshot }
                self.watchWrongSecret(snapshot.wrongSecret)
                ticks += 1
                // Every few seconds: is the port still listening? If not, bring it back by itself.
                if ticks % 3 == 0, self.isRunning, !self.isRecovering, !self.engine.isListening {
                    await self.recover()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The port stopped listening (a sleep, a change of the network, another program took it). Starts the proxy again on
    /// the same port, up to three times; if that fails, says so and switches the proxy off honestly.
    private func recover() async {
        isRecovering = true
        defer { isRecovering = false }
        let wanted = port
        engine.stop()
        for attempt in 1...3 {
            try? await Task.sleep(for: .seconds(attempt))
            guard isRunning else { return }
            do {
                port = try await engine.start(preferredPort: wanted)
                UserDefaults.standard.set(Int(port), forKey: Self.portKey)
                if port != wanted {
                    errorMessage = "Порт \(wanted) занят другой программой, прокси теперь на порту \(port). Нажмите «Открыть в Telegram», чтобы Telegram запомнил новый."
                }
                return
            } catch {
                continue
            }
        }
        poller?.cancel()
        isRunning = false
        autoStart = false
        stats = TelegramProxyStats()
        watchWrongSecret(0, reset: true)
        errorMessage = "Прокси остановился и не смог запуститься снова: порт \(wanted), возможно, занят другой программой. Включите его ещё раз."
    }
}
