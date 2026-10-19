import AppKit
import SwiftUI

/// The Telegram proxy as the window and the menu see it: on or off, the link, the numbers.
@MainActor
final class TelegramProxyModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var stats = TelegramProxyStats()
    @Published var errorMessage: String?
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey) }
    }

    private static let secretKey = "telegramProxySecret"
    private static let portKey = "telegramProxyPort"
    private static let autoStartKey = "telegramProxyAutoStart"

    let secretHex: String
    private let engine: TelegramProxyEngine
    private var poller: Task<Void, Never>?
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
        stats = TelegramProxyStats()
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
            while !Task.isCancelled {
                guard let self else { return }
                self.stats = self.engine.snapshot
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
