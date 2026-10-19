import SwiftUI

/// The three things Nimb switches, together: "turn everything on" and "turn everything off" for the home page and the
/// menu bar. They go one after another, because each of them may ask for the administrator password.
@MainActor
final class AllServices: ObservableObject {
    static let shared = AllServices()

    /// True while a batch is running.
    @Published private(set) var isRunning = false
    /// Which way the running batch goes.
    enum Intent { case none, on, off }
    @Published private(set) var intent = Intent.none

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?
    private var refresher: Timer?

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        self.dns = dns
        self.telegram = telegram
        self.warp = warp
        // The tunnel is a process of its own: it can end without Nimb doing anything. Read its state often, wherever the
        // person is looking (the window, the menu bar), not only while the tunnel page is open.
        refresher?.invalidate()
        refresher = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak warp] _ in
            Task { @MainActor in warp?.refresh() }
        }
    }

    var warpAvailable: Bool { warp?.phase != .unavailable }

    /// How many of the services work right now.
    var onCount: Int {
        guard let dns, let telegram, let warp else { return 0 }
        return [dns.active != nil, telegram.isRunning, warp.isOn].filter { $0 }.count
    }

    var total: Int { warpAvailable ? 3 : 2 }

    /// Which services work or are about to: one that is being switched on already counts as on, and during "turn everything
    /// on" all of them do. The rings of the home page and of the header follow this, so that they come together and not one
    /// after another as the services finish.
    var effective: (ai: Bool, telegram: Bool, media: Bool) {
        guard let dns, let telegram, let warp else { return (false, false, false) }
        if isRunning {
            switch intent {
            case .on: return (true, true, warpAvailable)
            case .off: return (false, false, false)
            case .none: break
            }
        }
        return (dns.isBusy ? dns.active == nil : dns.active != nil,
                telegram.isStarting ? true : telegram.isRunning,
                warp.isWorking ? warp.isTurningOn : warp.isOn)
    }

    var effectiveCount: Int { let e = effective; return [e.ai, e.telegram, e.media].filter { $0 }.count }
    var allOn: Bool { onCount == total }

    /// Something is changing, so that another change has to wait.
    var isBusy: Bool {
        guard let dns, let telegram, let warp else { return false }
        return isRunning || dns.isLocked || telegram.isStarting || warp.isWorking
    }

    func toggleWarp() {
        guard let warp else { return }
        if warp.isOn { warp.disconnect() } else if warp.phase == .notInstalled { warp.enable() } else { warp.connect() }
    }

    func enableAll() {
        guard let dns, let telegram, let warp, !isBusy else { return }
        isRunning = true
        intent = .on
        Task {
            defer { isRunning = false; intent = .none }
            if !telegram.isRunning { telegram.start(); await settle() }
            if dns.active == nil {
                dns.toggle(); await settle()
                // The password was refused: do not ask again for the next one.
                if dns.active == nil { return }
            }
            if warpAvailable && !warp.isOn { toggleWarp(); await settle() }
        }
    }

    func disableAll() {
        guard let dns, let telegram, let warp, !isBusy else { return }
        isRunning = true
        intent = .off
        Task {
            defer { isRunning = false; intent = .none }
            if telegram.isRunning { telegram.stop() }
            if dns.active != nil {
                dns.toggle(); await settle()
                if dns.active != nil { return }
            }
            if warp.isOn { warp.disconnect(); await settle() }
        }
    }

    /// Waits until the previous change is over, so that the password prompts come one after another.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        while let dns, let telegram, let warp, dns.isLocked || warp.isWorking || telegram.isStarting {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
