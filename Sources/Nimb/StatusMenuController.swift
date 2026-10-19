import AppKit
import Combine
import SwiftUI

/// The Nimb icon in the menu bar and the panel that opens from it (`MenuBarPanel`), whatever the window is doing. It is there
/// while background mode is on or something works. It is built with AppKit rather than SwiftUI's `MenuBarExtra`: inserting that
/// scene while the window was still opening made SwiftUI abort.
@MainActor
final class StatusMenuController: NSObject, NSPopoverDelegate {
    static let shared = StatusMenuController()

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?
    private var item: NSStatusItem?
    private var popover: NSPopover?
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
                self?.update(visible: running || background || tunnelOn || active != nil, working: running || tunnelOn || active != nil)
            }
    }

    /// Whether the icon is in the menu bar right now.
    var isShown: Bool { item?.isVisible ?? false }

    private func update(visible: Bool, working: Bool) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.target = self
            created.button?.action = #selector(togglePanel)
            created.button?.image = Self.icon
            created.button?.toolTip = "Nimb"
            item = created
        } else if !visible, let existing = item {
            popover?.close()
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
        // Dim when nothing works, bright when something does.
        item?.button?.alphaValue = working ? 1 : 0.45
    }

    /// The small ring of Nimb (the two halves of `Art/header`): a template image, so that macOS tints it for light and dark bars.
    static let icon: NSImage = {
        let size = NSSize(width: 36, height: 21)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for file in ["ring-back.png", "ring-front.png"] {
                if let ring = ArtLibrary.shared.image("header", file) {
                    // The picture is 336 x 194 pt with the ring in the middle; here it is drawn at about a tenth, a little larger.
                    let scale: CGFloat = 0.107
                    let width = 336 * scale, height = 194 * scale
                    context.draw(ring, in: CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: Panel

    @objc func togglePanel() {
        if let popover, popover.isShown { popover.close(); return }
        guard let dns, let telegram, let button = item?.button else { return }
        dns.refresh()
        warp?.refresh()
        let panel = MenuBarPanel(dns: dns, telegram: telegram, close: { [weak self] in self?.popover?.close() },
                                 openWindow: { [weak self] page in self?.showWindow(page) })
        let controller = NSHostingController(rootView: panel)
        controller.sizingOptions = [.preferredContentSize]
        let shown = NSPopover()
        shown.behavior = .transient
        shown.animates = true
        shown.appearance = NSAppearance(named: .darkAqua)
        shown.contentViewController = controller
        shown.delegate = self
        popover = shown
        shown.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) { popover = nil }

    /// Brings the window forward, on a page if one is asked for.
    func showWindow(_ page: AppPage? = nil) {
        popover?.close()
        if let page { Navigation.shared.select(page) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            AppDelegate.openMainWindow?()
        }
    }
}
