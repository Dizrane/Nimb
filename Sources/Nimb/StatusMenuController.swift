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

    /// What the ring shows: nothing works (a faint dashed ring), part of it works (a ring), all of it works
    /// (a thicker ring). There is no coloured dot: a green one in the menu bar looks like the sign of a camera in use.
    enum IconState { case off, partial, all }

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
        }
        guard let button = item?.button else { return }
        button.image = Self.icon(state)
        button.toolTip = "Nimb"
        button.setAccessibilityLabel("Nimb")
        button.setAccessibilityHelp("Открыть меню Nimb")
        button.setAccessibilityValue(state == .off ? "ничего не работает" : (state == .partial ? "работает часть сервисов" : "работает всё"))
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

    private let master = NSMenuItem()
    /// Shown only while a newer version exists (or is being installed): pressing it installs the update, the window is not needed.
    private let updateItem = NSMenuItem()
    private let updateSeparator = NSMenuItem.separator()
    private let aiItem = NSMenuItem()
    private let aiToggle = NSMenuItem()
    private var aiProviders: [NSMenuItem] = []
    private let tgItem = NSMenuItem()
    private let tgToggle = NSMenuItem()
    private let tgOpen = NSMenuItem()
    private let tgCopy = NSMenuItem()
    private let warpItem = NSMenuItem()
    private var watching: [AnyCancellable] = []

    /// The items are made once and only changed afterwards. A menu that is rebuilt on every opening shows the state of the
    /// moment it opened and never changes while it is open: that is why a person had to open it again and again.
    private func build(_ menu: NSMenu) {
        updateItem.target = self; updateItem.action = #selector(installUpdate); updateItem.image = symbol("arrow.down.circle")
        updateItem.isHidden = true
        updateSeparator.isHidden = true
        menu.addItem(updateItem)
        menu.addItem(updateSeparator)
        master.target = self; master.action = #selector(toggleAll); master.image = symbol("power")
        menu.addItem(master)
        menu.addItem(.separator())

        aiToggle.target = self; aiToggle.action = #selector(toggleDNS)
        let aiMenu = NSMenu()
        aiMenu.addItem(aiToggle)
        aiMenu.addItem(.separator())
        for provider in DNSProvider.all {
            let entry = NSMenuItem(title: provider.name, action: #selector(selectProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = provider.id
            aiMenu.addItem(entry)
            aiProviders.append(entry)
        }
        aiItem.submenu = aiMenu
        menu.addItem(aiItem)

        tgToggle.target = self; tgToggle.action = #selector(toggleProxy)
        tgOpen.title = "Открыть в Telegram"; tgOpen.target = self; tgOpen.action = #selector(openInTelegram)
        tgCopy.title = "Скопировать ссылку"; tgCopy.target = self; tgCopy.action = #selector(copyLink)
        let tgMenu = NSMenu()
        [tgToggle, .separator(), tgOpen, tgCopy].forEach { tgMenu.addItem($0) }
        tgItem.submenu = tgMenu
        menu.addItem(tgItem)

        warpItem.target = self; warpItem.action = #selector(toggleWarp)
        menu.addItem(warpItem)

        menu.addItem(.separator())
        menu.addItem(action("Открыть Nimb", #selector(showWindow)))
        menu.addItem(action("Выйти", #selector(quit)))
        refreshItems()
    }

    /// Sets every item to the state of the moment. Called when the menu opens and on every change while it is open.
    private func refreshItems() {
        guard let dns, let telegram, let warp else { return }
        let all = AllServices.shared

        switch UpdateViewModel.shared.state {
        case .available(let release):
            updateItem.title = "Обновить до \(release.version)"
            updateItem.isEnabled = !dns.isLocked
            updateItem.isHidden = false
            updateSeparator.isHidden = false
        case .installing(let text):
            updateItem.title = text
            updateItem.isEnabled = false
            updateItem.isHidden = false
            updateSeparator.isHidden = false
        case .failed:
            updateItem.title = "Не удалось обновить, открыть Nimb"
            updateItem.isEnabled = true
            updateItem.isHidden = false
            updateSeparator.isHidden = false
        default:
            updateItem.isHidden = true
            updateSeparator.isHidden = true
        }
        master.title = all.isRunning ? "Подождите…" : (all.allOn ? "Выключить всё" : "Включить всё")
        master.isEnabled = !all.isBusy

        // Neural networks: a check mark when it works, a dash while it is being switched.
        let aiBusy = dns.isBusy || dns.isProbing || dns.isSettingUp
        aiItem.state = aiBusy ? .mixed : (dns.active != nil ? .on : .off)
        aiItem.attributedTitle = titled("Нейросети", detail: aiBusy ? "переключаю…" : dns.active?.name)
        aiToggle.title = dns.active != nil ? "Выключить" : "Включить (\(dns.selected.name))"
        aiToggle.isEnabled = !dns.isLocked
        for (entry, provider) in zip(aiProviders, DNSProvider.all) {
            entry.state = (dns.active ?? dns.selected) == provider ? .on : .off
            entry.isEnabled = !dns.isLocked
        }

        let tgBusy = telegram.isStarting
        tgItem.state = tgBusy ? .mixed : (telegram.isRunning ? .on : .off)
        tgItem.attributedTitle = titled("Telegram", detail: tgBusy ? "запускаю…" : (telegram.isRunning ? "127.0.0.1:\(String(telegram.port))" : nil))
        tgToggle.title = telegram.isRunning ? "Остановить прокси" : "Включить прокси"
        tgToggle.isEnabled = !tgBusy
        tgOpen.isHidden = !telegram.isRunning
        tgCopy.isHidden = !telegram.isRunning
        tgToggle.menu?.items.first { $0.isSeparatorItem }?.isHidden = !telegram.isRunning

        if warp.phase == .unavailable {
            warpItem.isHidden = true
        } else {
            warpItem.isHidden = false
            if case .working(let text) = warp.phase {
                warpItem.state = .mixed
                warpItem.attributedTitle = titled("YouTube и Discord", detail: text.lowercased())
                warpItem.isEnabled = false
            } else {
                warpItem.state = warp.isOn ? .on : .off
                warpItem.attributedTitle = titled("YouTube и Discord", detail: nil)
                warpItem.isEnabled = !all.isBusy
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === item?.menu, dns != nil else { return }
        if menu.items.isEmpty { build(menu) }
        dns?.refresh()
        warp?.refresh()
        refreshItems()
    }

    /// While the menu is open, it follows every change of the services.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === item?.menu, let dns, let telegram, let warp else { return }
        let all = AllServices.shared
        let changes: [AnyPublisher<Void, Never>] = [
            dns.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            telegram.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            warp.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            all.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            UpdateViewModel.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
        ]
        // `objectWillChange` fires before the value is set: look at the state on the next turn of the main queue.
        watching = changes.map { publisher in
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.refreshItems() }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === item?.menu else { return }
        watching.removeAll()
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

    @objc private func showWindow() { AppDelegate.showMainWindow() }

    /// The line at the top of the menu: opens the window of the update, the same as the button at the bottom of the window.
    @objc private func installUpdate() {
        // The window of the update shows what is new, and the installation step by step; after a failure it says where it stopped.
        UpdateWindowController.shared.show()
    }
}
