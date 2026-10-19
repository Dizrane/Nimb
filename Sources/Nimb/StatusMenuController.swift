import AppKit
import Combine

/// The Nimb icon in the menu bar: the DNS switch and the Telegram proxy, whatever the window is doing. It is there while
/// background mode is on or the proxy runs. It is built with AppKit rather than SwiftUI's `MenuBarExtra`: inserting that
/// scene while the window was still opening made SwiftUI abort.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let shared = StatusMenuController()

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel) {
        guard self.dns == nil else { return }
        self.dns = dns
        self.telegram = telegram
        subscription = Publishers.CombineLatest3(telegram.$isRunning, BackgroundMode.shared.$enabled, dns.$active)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, background, active in
                self?.update(visible: running || background, dnsOn: active != nil)
            }
    }

    /// Whether the icon is in the menu bar right now.
    var isShown: Bool { item?.isVisible ?? false }
    var menu: NSMenu? { item?.menu }

    private func update(visible: Bool, dnsOn: Bool) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            created.menu = menu
            item = created
        } else if !visible, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
        item?.button?.image = Self.icon(dnsOn: dnsOn)
        item?.button?.toolTip = "Nimb"
    }

    /// A thin halo; with a planet under it while DNS is on. A template image, so that macOS tints it.
    static func icon(dnsOn: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ringRect = dnsOn ? NSRect(x: 1.5, y: 11, width: 17, height: 5.5) : NSRect(x: 1.5, y: 6, width: 17, height: 6)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 1.5
            ring.stroke()
            if dnsOn { NSBezierPath(ovalIn: NSRect(x: 5.5, y: 1.5, width: 9, height: 9)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let dns, let telegram else { return }
        dns.refresh()
        menu.removeAllItems()

        menu.addItem(label("DNS"))
        if let active = dns.active {
            menu.addItem(plain("● \(active.name): включён"))
            menu.addItem(action("Выключить DNS", #selector(toggleDNS), enabled: !dns.isLocked))
        } else {
            menu.addItem(plain("○ Выключен (DNS роутера или провайдера)"))
            menu.addItem(action("Включить DNS (\(dns.selected.name))", #selector(toggleDNS), enabled: !dns.isLocked))
        }
        let providers = NSMenuItem(title: "Сервис DNS", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for provider in DNSProvider.all {
            let entry = NSMenuItem(title: provider.name, action: #selector(selectProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = provider.id
            entry.state = (dns.active ?? dns.selected) == provider ? .on : .off
            entry.isEnabled = !dns.isLocked
            submenu.addItem(entry)
        }
        providers.submenu = submenu
        menu.addItem(providers)

        menu.addItem(.separator())
        menu.addItem(label("Telegram"))
        if telegram.isRunning {
            menu.addItem(plain("● Прокси работает на 127.0.0.1:\(String(telegram.port))"))
            menu.addItem(action("Остановить прокси", #selector(toggleProxy)))
            menu.addItem(action("Открыть в Telegram", #selector(openInTelegram)))
            menu.addItem(action("Скопировать ссылку", #selector(copyLink)))
        } else {
            menu.addItem(plain("○ Прокси выключен"))
            menu.addItem(action("Включить прокси", #selector(toggleProxy)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Показать окно Nimb", #selector(showWindow)))
        menu.addItem(action("Выйти из Nimb", #selector(quit)))
    }

    private func label(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem()
        entry.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.2,
        ])
        entry.isEnabled = false
        return entry
    }

    private func plain(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    @objc private func toggleDNS() { dns?.toggle() }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let provider = DNSProvider.all.first(where: { $0.id == id }) else { return }
        dns?.select(provider)
    }

    @objc private func toggleProxy() { telegram?.toggle() }
    @objc private func openInTelegram() { telegram?.openInTelegram() }
    @objc private func copyLink() { telegram?.copyLink() }
    @objc private func quit() { AppDelegate.quit() }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            AppDelegate.openMainWindow?()
        }
    }
}
