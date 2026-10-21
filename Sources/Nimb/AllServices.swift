import Combine
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
    private var forwarding: [AnyCancellable] = []

    /// Set when the services are known. Everything that reads `effective` redraws then: it was asked before and got "nothing works".
    @Published private(set) var isConfigured = false

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        self.dns = dns
        self.telegram = telegram
        self.warp = warp
        isConfigured = true
        // A change of any of the three is a change of this object: whoever shows the services needs to watch only this one.
        forwarding = [
            dns.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            telegram.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            warp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
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

    // MARK: One service

    /// The service as the switches, the sidebar and the menu bar panel see it. `page` is one of `AppPage.services`.
    func isOn(_ page: AppPage) -> Bool {
        guard let dns, let telegram, let warp else { return false }
        switch page {
        case .ai: return dns.active != nil
        case .telegram: return telegram.isRunning
        case .media: return warp.isOn
        default: return false
        }
    }

    /// The service is being switched: a spinner instead of the switch until its state is final.
    func isPending(_ page: AppPage) -> Bool {
        guard let dns, let telegram, let warp else { return false }
        switch page {
        case .ai: return dns.isBusy || dns.isProbing || dns.isSettingUp
        case .telegram: return telegram.isStarting
        case .media: return warp.isWorking
        default: return false
        }
    }

    /// The service cannot be switched now (it is unavailable in this build, or something else is changing).
    func isLocked(_ page: AppPage) -> Bool {
        guard let warp else { return true }
        if page == .media && warp.phase == .unavailable { return true }
        return isBusy
    }

    /// The second line under the name of the service.
    func detail(_ page: AppPage) -> String {
        guard let dns, let telegram, let warp else { return "" }
        switch page {
        case .ai: return dns.active?.name ?? "ChatGPT, Claude, Gemini и другие"
        case .telegram: return telegram.isRunning ? "Прокси работает" : "Прокси для Telegram Desktop"
        case .media: return warp.isOn ? "Туннель работает" : (warp.phase == .unavailable ? "Недоступно в этой сборке" : "Туннель WARP")
        default: return ""
        }
    }

    func toggle(_ page: AppPage) {
        guard let dns, let telegram else { return }
        switch page {
        case .ai: dns.toggle()
        case .telegram: telegram.toggle()
        case .media: toggleWarp()
        default: break
        }
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
            let needDNS = dns.active == nil, needWarp = warpAvailable && !warp.isOn
            if needDNS && needWarp && dns.asksPassword && warp.asksPassword(turningOn: true) {
                // Both want the administrator password: it is asked once, for the two together.
                PrivilegedBatch.shared.expect(2)
                dns.toggle()
                toggleWarp()
                await settle()
                return
            }
            if needDNS {
                dns.toggle(); await settle()
                // The password was refused: do not ask again for the next one.
                if dns.active == nil { return }
            }
            if needWarp { toggleWarp(); await settle() }
        }
    }

    func disableAll() {
        guard let dns, let telegram, let warp, !isBusy else { return }
        isRunning = true
        intent = .off
        Task {
            defer { isRunning = false; intent = .none }
            if telegram.isRunning { telegram.stop() }
            if dns.active != nil && warp.isOn && dns.asksPassword && warp.asksPassword(turningOn: false) {
                PrivilegedBatch.shared.expect(2)
                dns.toggle()
                warp.disconnect()
                await settle()
                return
            }
            if dns.active != nil {
                dns.toggle(); await settle()
                if dns.active != nil { return }
            }
            if warp.isOn { warp.disconnect(); await settle() }
        }
    }

    /// Whether anything of Nimb is still working: a service that would go on after the program is gone.
    var anythingWorks: Bool {
        guard let dns, let telegram, let warp else { return false }
        return dns.active != nil || telegram.isRunning || warp.isOn
    }

    /// The services that still work, by name.
    var stillWorking: [String] {
        guard let dns, let telegram, let warp else { return [] }
        var names: [String] = []
        if dns.active != nil { names.append("DNS нейросетей") }
        if telegram.isRunning { names.append("прокси Telegram") }
        if warp.isOn { names.append("туннель YouTube и Discord") }
        return names
    }

    /// Before the program ends: turns off all three. Unlike «Выключить всё» it goes on to the next one if one was refused (the
    /// administrator password), and says in the end which of them still work. Waits for what is changing now.
    func shutdown() async -> [String] {
        guard let dns, let telegram, let warp else { return [] }
        while isBusy { try? await Task.sleep(for: .milliseconds(150)) }
        isRunning = true
        intent = .off
        defer { isRunning = false; intent = .none }
        if telegram.isRunning { telegram.stop() }
        if dns.active != nil && warp.isOn && dns.asksPassword && warp.asksPassword(turningOn: false) {
            PrivilegedBatch.shared.expect(2)
            dns.toggle()
            warp.disconnect()
            await settle()
        } else {
            if dns.active != nil { dns.toggle(); await settle() }
            if warp.isOn { warp.disconnect(); await settle() }
        }
        warp.refresh()
        return stillWorking
    }

    /// Waits until the previous change is over, so that the password prompts come one after another.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        while let dns, let telegram, let warp, dns.isLocked || warp.isWorking || telegram.isStarting {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
