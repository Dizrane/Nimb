import SwiftUI

@main
struct NimbApp: App {
    @StateObject private var telegram = TelegramProxyModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Nimb", id: "main") {
            ContentView()
                .environmentObject(telegram)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // While the Telegram proxy runs, Nimb stays in the menu bar so that the window can be closed.
        MenuBarExtra(isInserted: Binding(get: { telegram.isRunning }, set: { _ in })) {
            Text("Telegram-прокси: 127.0.0.1:\(String(telegram.port))")
            Button("Открыть в Telegram") { telegram.openInTelegram() }
            Button("Скопировать ссылку") { telegram.copyLink() }
            Divider()
            Button("Остановить прокси") { telegram.stop() }
            Button("Показать окно Nimb") { showWindow() }
            Divider()
            Button("Выйти из Nimb") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: TelegramProxyModel.menuBarImage())
        }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
