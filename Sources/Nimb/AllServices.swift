import SwiftUI

/// The three things Nimb switches, together: "turn everything on" and "turn everything off" for the home page and the
/// menu bar. They go one after another, because each of them may ask for the administrator password.
@MainActor
final class AllServices: ObservableObject {
    static let shared = AllServices()

    /// True while a batch is running.
    @Published private(set) var isRunning = false

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        self.dns = dns
        self.telegram = telegram
        self.warp = warp
    }

    var warpAvailable: Bool { warp?.phase != .unavailable }

    /// How many of the services work right now.
    var onCount: Int {
        guard let dns, let telegram, let warp else { return 0 }
        return [dns.active != nil, telegram.isRunning, warp.isOn].filter { $0 }.count
    }

    var total: Int { warpAvailable ? 3 : 2 }
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
        Task {
            if !telegram.isRunning { telegram.start(); await settle() }
            if dns.active == nil { dns.toggle(); await settle() }
            if warpAvailable && !warp.isOn { toggleWarp(); await settle() }
            isRunning = false
        }
    }

    func disableAll() {
        guard let dns, let telegram, let warp, !isBusy else { return }
        isRunning = true
        Task {
            if telegram.isRunning { telegram.stop() }
            if dns.active != nil { dns.toggle(); await settle() }
            if warp.isOn { warp.disconnect(); await settle() }
            isRunning = false
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
