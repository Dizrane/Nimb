import AppKit
import Combine

/// The Nimb icon in the menu bar: one switch for everything and one for each of the three services, whatever the window is
/// doing. It is there while background mode is on or something works. It is built with AppKit rather than SwiftUI's `MenuBarExtra`: inserting that
/// scene while the window was still opening made SwiftUI abort.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let shared = StatusMenuController()

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        guard self.dns == nil else { return }
        self.dns = dns
        self.telegram = telegram
        self.warp = warp
        AllServices.shared.configure(dns: dns, telegram: telegram, warp: warp)
        subscription = Publishers.CombineLatest4(telegram.$isRunning, BackgroundMode.shared.$enabled, dns.$active, warp.$phase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, background, active, tunnel in
                var tunnelOn = false
                if case .on = tunnel { tunnelOn = true }
                let count = [active != nil, running, tunnelOn].filter { $0 }.count
                let total = tunnel == .unavailable ? 2 : 3
                let state: IconState = count == 0 ? .off : (count == total ? .all : .partial)
                self?.update(visible: running || background || tunnelOn || active != nil, state: state)
            }
    }

    /// Whether the icon is in the menu bar right now.
    var isShown: Bool { item?.isVisible ?? false }
    var menu: NSMenu? { item?.menu }

    /// What the ring shows: nothing works (a faint dashed ring), part of it works (a ring and a green dot), all of it works
    /// (a thicker ring and the dot).
    enum IconState { case off, partial, all }

    private var dot: NSView?

    private func update(visible: Bool, state: IconState) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            created.menu = menu
            item = created
        } else if !visible, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
            dot = nil
        }
        guard let button = item?.button else { return }
        button.image = Self.icon(state)
        button.toolTip = "Nimb"
        // The dot is a view over the button: the ring is a template image that macOS tints, and a template cannot be green.
        if dot == nil {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(Theme.ok).cgColor
            view.layer?.cornerRadius = 2.75
            view.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(view)
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 5.5),
                view.heightAnchor.constraint(equalToConstant: 5.5),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                view.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
            ])
            dot = view
        }
        dot?.isHidden = state == .off
    }

    /// The halo of Nimb as a ring; a template image, so that macOS tints it for light and dark menu bars.
    static func icon(_ state: IconState) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 6, width: 17, height: 6))
            switch state {
            case .off:
                NSColor.black.withAlphaComponent(0.5).setStroke()
                ring.lineWidth = 1.3
                ring.setLineDash([2.2, 2.0], count: 2, phase: 0)
            case .partial:
                NSColor.black.setStroke()
                ring.lineWidth = 1.5
            case .all:
                NSColor.black.setStroke()
                ring.lineWidth = 2.1
            }
            ring.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let dns, let telegram, let warp else { return }
        dns.refresh()
        warp.refresh()
        menu.removeAllItems()
        let all = AllServices.shared
        let busy = all.isBusy

        // One switch for everything.
        let master = action(all.allOn ? "Выключить всё" : "Включить всё", #selector(toggleAll), enabled: !busy)
        master.image = symbol("power")
        menu.addItem(master)
        menu.addItem(.separator())

        // Each service: a check mark when it works, the details one step deeper.
        let ai = NSMenuItem(title: "Нейросети", action: nil, keyEquivalent: "")
        ai.state = dns.active != nil ? .on : .off
        ai.attributedTitle = titled("Нейросети", detail: dns.active?.name)
        let aiMenu = NSMenu()
        aiMenu.addItem(action(dns.active != nil ? "Выключить" : "Включить (\(dns.selected.name))", #selector(toggleDNS), enabled: !dns.isLocked))
        aiMenu.addItem(.separator())
        for provider in DNSProvider.all {
            let entry = NSMenuItem(title: provider.name, action: #selector(selectProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = provider.id
            entry.state = (dns.active ?? dns.selected) == provider ? .on : .off
            entry.isEnabled = !dns.isLocked
            aiMenu.addItem(entry)
        }
        ai.submenu = aiMenu
        menu.addItem(ai)

        let tg = NSMenuItem(title: "Telegram", action: nil, keyEquivalent: "")
        tg.state = telegram.isRunning ? .on : .off
        tg.attributedTitle = titled("Telegram", detail: telegram.isRunning ? "127.0.0.1:\(String(telegram.port))" : nil)
        let tgMenu = NSMenu()
        tgMenu.addItem(action(telegram.isRunning ? "Остановить прокси" : "Включить прокси", #selector(toggleProxy), enabled: !telegram.isStarting))
        if telegram.isRunning {
            tgMenu.addItem(.separator())
            tgMenu.addItem(action("Открыть в Telegram", #selector(openInTelegram)))
            tgMenu.addItem(action("Скопировать ссылку", #selector(copyLink)))
        }
        tg.submenu = tgMenu
        menu.addItem(tg)

        switch warp.phase {
        case .unavailable:
            break
        case .working(let text):
            let entry = NSMenuItem(title: "YouTube и Discord: \(text)", action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        default:
            let entry = action("YouTube и Discord", #selector(toggleWarp), enabled: !busy)
            entry.state = warp.isOn ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(action("Открыть Nimb", #selector(showWindow)))
        menu.addItem(action("Выйти", #selector(quit)))
    }

    /// A title with a quiet second part on the same line.
    private func titled(_ title: String, detail: String?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if let detail {
            text.append(NSAttributedString(string: "  \(detail)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    @objc private func toggleAll() {
        let all = AllServices.shared
        if all.allOn { all.disableAll() } else { all.enableAll() }
    }

    @objc private func toggleDNS() { dns?.toggle() }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let provider = DNSProvider.all.first(where: { $0.id == id }) else { return }
        dns?.select(provider)
    }

    @objc private func toggleProxy() { telegram?.toggle() }
    @objc private func toggleWarp() { AllServices.shared.toggleWarp() }
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
