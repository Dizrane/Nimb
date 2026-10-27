import Foundation

/// The black box: every five minutes one line of facts about what works and whether it works as it should, kept for a day in a small file on
/// this Mac (it goes nowhere by itself). A report, by hand or sent by the program, carries its last lines, so that what happened before the
/// trouble is there even when it is found an hour later. Nothing in it names the person, and it asks the net for nothing.
@MainActor
final class BlackBox {
    static let shared = BlackBox()

    static let interval: TimeInterval = 5 * 60
    /// Lines that go into a report: five hours.
    nonisolated static let reportLines = 60

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?
    private var timer: Timer?
    private let started = Date()
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("Logs/Nimb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("blackbox.log")
    }

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        guard self.dns == nil else { return }
        self.dns = dns; self.telegram = telegram; self.warp = warp
        // The first line a little after the start (the services are being switched on then), the next ones on the clock of five minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.record() }
        let created = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record() }
        }
        created.tolerance = 30
        timer = created
    }

    // MARK: Writing

    private func record() {
        guard let dns, let telegram, let warp else { return }
        Task {
            // What Nimb thinks of the DNS is first made to follow the system (see `syncFromSystem`).
            await dns.syncFromSystem()
            Notifier.shared.dnsWarning(dns.warnings)
            self.recordNow(dns: dns, telegram: telegram, warp: warp)
        }
    }

    private func recordNow(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        // What the models know now (on the main thread), then what the system says (off it).
        let active = dns.active
        let tgRunning = telegram.isRunning, tgPort = telegram.port, tgListening = telegram.isListening, tgStats = telegram.stats
        let tunnelOn = warp.isOn
        let tunnelWorking = if case .working = warp.phase { true } else { false }
        let tunnelWords = BlackBoxLine.phaseWords(warp.phase)
        let uptime = Date().timeIntervalSince(started)
        Task.detached(priority: .utility) {
            let system = DiagnosticReport.snapshot(network: false)
            let tgAgrees = AutoReportRules.telegramAgrees(running: tgRunning, listening: tgListening)
            let dnsAgrees = AutoReportRules.dnsAgrees(active: active, serviceServers: system.serviceServers)
            let viaTunnel = system.interface.hasPrefix("utun")
            let handshake = tunnelOn ? (try? String(contentsOfFile: WarpPaths.daemonLog, encoding: .utf8)).flatMap { TunnelHandshake.age(inLog: $0, now: Date()) } : nil
            let facts = BlackBoxLine.Facts(
                dns: active?.name ?? "выкл", dnsAgrees: dnsAgrees,
                telegram: tgRunning ? "вкл:\(tgPort) соединений=\(tgStats.totalConnections) ошибок=\(tgStats.failures)" : "выкл", telegramAgrees: tgAgrees,
                tunnel: tunnelWords, tunnelAgrees: AutoReportRules.tunnelAgrees(on: tunnelOn, routes: system.routes, viaTunnel: viaTunnel, working: tunnelWorking),
                routes: system.routes, interface: system.interface, handshakeSeconds: handshake)
            let line = BlackBoxLine.line(now: Date(), uptime: uptime, facts: facts, memoryMegabytes: BlackBoxLine.residentMegabytes())
            await MainActor.run {
                self.append(line)
                AutoReporter.shared.observe(facts)
            }
        }
    }

    private func append(_ line: String) {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let kept = BlackBoxLine.trimmed(existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) + [line])
        try? (kept.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    /// The last lines for a report, oldest first.
    nonisolated static func lastLines(_ count: Int = reportLines) -> [String] {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = base.appendingPathComponent("Logs/Nimb/blackbox.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(count))
    }
}

/// The pure parts of the black box: the line and its facts.
enum BlackBoxLine {
    /// Lines kept: a day of lines every five minutes.
    static let keepLines = 288

    /// What the line says about each service: it is on, and the facts agree with that.
    struct Facts {
        var dns: String
        var dnsAgrees: Bool
        var telegram: String
        var telegramAgrees: Bool
        var tunnel: String
        var tunnelAgrees: Bool
        var routes: Int
        var interface: String
        /// Seconds since the server of the tunnel last answered (only while it is on, and only when the log of the daemon says).
        var handshakeSeconds: Int?
    }

    static func phaseWords(_ phase: WarpTunnelModel.Phase) -> String {
        switch phase {
        case .unavailable: "нет"
        case .notInstalled: "не установлен"
        case .off: "выкл"
        case .working(let text): "в работе (\(text))"
        case .on(let interface): "вкл:\(interface)"
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// One line of key=value pairs: made to be read by a program (and by a person who knows what the keys are).
    static func line(now: Date, uptime: TimeInterval, facts: Facts, memoryMegabytes: Int) -> String {
        func ok(_ value: Bool) -> String { value ? "да" : "НЕТ" }
        let hours = Int(uptime) / 3600, minutes = Int(uptime) % 3600 / 60
        return [
            stamp.string(from: now),
            "работает=\(hours)ч\(String(format: "%02d", minutes))м",
            "dns=\(facts.dns) совпало=\(ok(facts.dnsAgrees))",
            "telegram=\(facts.telegram) совпало=\(ok(facts.telegramAgrees))",
            "туннель=\(facts.tunnel) совпало=\(ok(facts.tunnelAgrees)) маршрутов=\(facts.routes)" + (facts.handshakeSeconds.map { " рукопожатие=\($0)с" } ?? ""),
            "трафик_через=\(facts.interface)",
            "память=\(memoryMegabytes)МБ",
        ].joined(separator: " | ")
    }

    /// The memory that the program holds now, in megabytes.
    static func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : 0
    }

    /// A day of lines and no more.
    static func trimmed(_ lines: [String]) -> [String] { Array(lines.suffix(keepLines)) }
}
