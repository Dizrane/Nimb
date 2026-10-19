import AppKit
import Combine

/// The halo in the menu bar that stays while the Telegram proxy runs, with the few actions that matter. It is built with
/// AppKit rather than SwiftUI's `MenuBarExtra`: inserting that scene while the window is still opening made SwiftUI abort.
@MainActor
final class TelegramStatusItem: NSObject, NSMenuDelegate {
    private unowned let model: TelegramProxyModel
    private var item: NSStatusItem?
    private var titleItem: NSMenuItem?
    private var subscription: AnyCancellable?

    init(model: TelegramProxyModel) {
        self.model = model
        super.init()
        subscription = model.$isRunning.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] running in
            self?.update(running: running)
        }
    }

    /// Whether the icon is in the menu bar right now.
    var isShown: Bool { item?.isVisible ?? false }

    private func update(running: Bool) {
        if running, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.image = TelegramProxyModel.menuBarImage()
            created.button?.toolTip = "Nimb: прокси для Telegram работает"
            created.menu = makeMenu()
            item = created
        } else if !running, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.isEnabled = false
        titleItem = title
        menu.addItem(title)
        menu.addItem(action("Открыть в Telegram", #selector(openInTelegram)))
        menu.addItem(action("Скопировать ссылку", #selector(copyLink)))
        menu.addItem(.separator())
        menu.addItem(action("Остановить прокси", #selector(stopProxy)))
        menu.addItem(action("Показать окно Nimb", #selector(showWindow)))
        menu.addItem(.separator())
        menu.addItem(action("Выйти из Nimb", #selector(quit)))
        return menu
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    func menuWillOpen(_ menu: NSMenu) {
        titleItem?.title = "Telegram-прокси: 127.0.0.1:\(String(model.port))"
    }

    @objc private func openInTelegram() { model.openInTelegram() }
    @objc private func copyLink() { model.copyLink() }
    @objc private func stopProxy() { model.stop() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            model.openMainWindow?()
        }
    }
}
