import AppKit
import Foundation

/// The text of a report about a problem: what the person wrote, the state of the three services, the last answers of the checks,
/// a few facts about the network and the end of the diary. No keys, no passwords, no addresses of the person (`ReportRedactor`).
@MainActor
enum DiagnosticReport {
    /// Everything but what the person typed. It takes a few seconds (it asks Cloudflare which country the traffic leaves from).
    static func collect(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) async -> String {
        var out: [String] = []

        let system = await Task.detached(priority: .utility) { snapshot() }.value
        let helper = WarpTunnelModel.helperVersions()

        out.append(section("Программа", [
            "Nimb \(Updater.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)",
            "Язык системы: \(Locale.preferredLanguages.first ?? "?"), часовой пояс UTC\(utcOffset)",
            "Окно: \(Int(NSApp.windows.first { $0.canBecomeMain }?.frame.width ?? 0))×\(Int(NSApp.windows.first { $0.canBecomeMain }?.frame.height ?? 0))",
            "Прошлый запуск закончился неожиданно: \(yes(SessionMarker.previousEndedBadly))",
            "Работа в фоне: \(yes(BackgroundMode.shared.enabled)), автозапуск: \(yes(LaunchAtLogin.shared.isOn))",
            "Помощник туннеля: стоит версия \(helper.installed.map(String.init) ?? "нет"), в приложении \(helper.bundled.map(String.init) ?? "нет")",
        ]))

        out.append(section("Сервисы", [
            "Нейросети (DNS): \(dns.active.map { "включено, \($0.name)" } ?? "выключено"); выбран \(dns.selected.name)",
            "  без пароля: \(yes(dns.passwordless))\(dns.access.tooBroad ? ", правило слишком широкое" : "")\(dns.access.missing.isEmpty ? "" : ", не покрыто подключений: \(dns.access.missing.count)")",
            "Telegram (прокси): \(telegram.isRunning ? "включено, порт \(telegram.port)" : "выключено"); соединений \(telegram.stats.totalConnections), ошибок \(telegram.stats.failures), чужой ключ \(telegram.stats.wrongSecret)",
            "YouTube и Discord (туннель): \(phaseText(warp.phase)); без пароля: \(yes(warp.passwordless)); установлен: \(yes(warp.isInstalled))",
        ]))

        out.append(section("Что ждали и что увидели", [
            ReportChecks.dns(active: dns.active, serviceServers: system.serviceServers, resolver: system.resolver),
            ReportChecks.telegram(running: telegram.isRunning, port: telegram.port, listening: telegram.isListening, stats: telegram.stats),
            ReportChecks.tunnel(on: warp.isOn, routes: system.routes, interface: system.interface, warp: system.warp, dropped: system.dropped),
        ].flatMap(\.lines)))

        let shown = [dns.errorMessage, telegram.errorMessage, warp.errorMessage].compactMap { $0 }
        if !shown.isEmpty { out.append(section("Ошибки на экране", shown)) }
        if !dns.warnings.isEmpty { out.append(section("Предупреждения DNS", dns.warnings)) }

        if !warp.checks.isEmpty {
            out.append(section("Проверка YouTube и Discord", warp.checks.flatMap { check in
                ["\(check.name): \(check.result)"] + check.probes.map { "  \($0.name) (\($0.host)): \($0.answered ? "ответ \($0.code), \(String(format: "%.1f", $0.seconds)) с" : ($0.failure ?? "нет ответа"))" }
            }))
        }
        if !dns.reports.isEmpty {
            out.append(section("Проверка DNS", dns.reports.map { report in
                let services = report.services.map { "\($0.name) \($0.answered)/\($0.total)" }.joined(separator: ", ")
                return "\(report.provider.name): работает \(report.workingCount) из \(report.services.count) (\(services))"
            }))
        }

        out.append(section("Сеть", system.lines))
        out.append(section("Что могло помешать", ReportChecks.interference(system)))

        // The diary: first the events of the last day (what was switched on and off, and every error), then its last lines as they are.
        let diary = AppLog.shared.recent(500)
        out.append(section("Хронология (последние сутки)", ReportChronology.events(from: diary, now: Date())))
        let tail = Array(diary.suffix(30))
        out.append(section("Журнал (последние строки)", tail.isEmpty ? ["пусто"] : tail))

        let services = await Task.detached(priority: .utility) { DNSManager.physicalServices() }.value
        return ReportRedactor.clean(out.joined(separator: "\n\n"), services: services)
    }

    /// The head of the report: the number, what the person wrote, how to answer.
    static func head(id: String, description: String, contact: String) -> String {
        var lines = ["Отчёт № \(id)", ""]
        lines.append("Что случилось:")
        lines.append(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(не описано)" : ReportRedactor.clean(description.trimmingCharacters(in: .whitespacesAndNewlines)))
        let reply = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty { lines.append(""); lines.append("Как ответить: \(reply)") }
        return lines.joined(separator: "\n")
    }

    /// The report cut to what one Telegram message takes: the oldest lines of the diary go first, the head and the facts stay.
    static func fitted(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let log = lines.firstIndex(where: { $0.hasPrefix("— Журнал") }) else { return String(text.prefix(limit)) }
        while lines.joined(separator: "\n").count > limit, lines.count > log + 2 { lines.remove(at: log + 1) }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    nonisolated static func newID() -> String {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in letters.randomElement() ?? "X" })
    }

    // MARK: Pieces

    private static func section(_ title: String, _ lines: [String]) -> String {
        "— \(title) —\n" + lines.joined(separator: "\n")
    }

    private static func yes(_ value: Bool) -> String { value ? "да" : "нет" }

    /// «+7», «-5», «+5:30»: the times of the diary are in this zone.
    private static var utcOffset: String {
        let seconds = TimeZone.current.secondsFromGMT()
        let minutes = abs(seconds) / 60 % 60
        return (seconds < 0 ? "-" : "+") + "\(abs(seconds) / 3600)" + (minutes == 0 ? "" : ":\(String(format: "%02d", minutes))")
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Intel"
        #endif
    }

    private static func phaseText(_ phase: WarpTunnelModel.Phase) -> String {
        switch phase {
        case .unavailable: "недоступно в этой сборке"
        case .notInstalled: "не установлено"
        case .off: "выключено"
        case .working(let text): "в работе: \(text)"
        case .on(let interface): "включено (\(interface))"
        }
    }

    /// Facts of the network, asked of the system and of Cloudflare. Never anything that names the person.
    nonisolated private static func snapshot() -> SystemSnapshot {
        var system = SystemSnapshot()
        var lines: [String] = []
        let route = run("/sbin/route", ["-n", "get", "1.1.1.1"])
        let interface = route.split(separator: "\n").first { $0.contains("interface:") }.map { $0.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?" } ?? "?"
        system.interface = interface
        lines.append("Трафик в интернет идёт через интерфейс: \(interface)\(interface.hasPrefix("utun") ? " (туннель)" : "")")

        let trace = run("/usr/bin/curl", ["-s", "-m", "6", "--connect-timeout", "4", "https://www.cloudflare.com/cdn-cgi/trace"])
        if trace.isEmpty {
            lines.append("Cloudflare не ответил за 6 секунд (интернета нет или он закрыт)")
        } else {
            let wanted = ["warp", "loc", "colo", "http"]
            let facts = trace.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 && wanted.contains(parts[0]) ? "\(parts[0])=\(parts[1])" : nil
            }
            lines.append("Cloudflare: \(facts.joined(separator: ", "))")
            system.warp = trace.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[0] == "warp" ? parts[1] : nil
            }.first
        }

        let services = DNSManager.physicalServices()
        for service in services {
            let servers = DNSManager.servers(of: service)
            system.serviceServers.append(servers)
            lines.append("DNS на «\(service)»: \(servers.isEmpty ? "автоматический" : servers.joined(separator: ", "))")
        }
        system.resolver = DNSManager.mainResolverServers()

        let state = (try? String(contentsOfFile: WarpPaths.stateFile, encoding: .utf8)) ?? ""
        if state.isEmpty {
            lines.append("Туннель: файла состояния нет")
        } else {
            let keys = ["pid", "interface", "watcher"]
            lines.append("Туннель: " + state.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 && keys.contains(parts[0]) ? "\(parts[0])=\(parts[1])" : nil
            }.joined(separator: ", "))
            system.routes = state.split(separator: "\n").filter { $0.hasPrefix("route=") }.count
            lines.append("Маршрутов туннеля: \(system.routes)")
        }
        lines.append("Помощник туннеля: \(FileManager.default.isExecutableFile(atPath: WarpPaths.helper) ? "есть" : "нет"), настройки: \(FileManager.default.fileExists(atPath: WarpPaths.config) ? "есть" : "нет")")
        system.lines = lines

        if let text = try? String(contentsOfFile: WarpPaths.droppedFile, encoding: .utf8), let drop = TunnelDrop.parse(text),
           Date().timeIntervalSince(drop.when) < TunnelDrop.newsFor {
            system.dropped = "\(drop.reason) в \(drop.when.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))"
        }
        system.proxies = ReportChecks.proxies(from: run("/usr/sbin/scutil", ["--proxy"]))
        system.vpnConnected = ReportChecks.connectedVPNs(from: run("/usr/sbin/scutil", ["--nc", "list"]))
        let domains = ProbeTarget.all.map(\.host) + ["telegram.org", "t.me", "youtube.com", "discord.com"]
        system.hostsMentions = ReportChecks.hostsMentions(in: (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "", domains: domains)
        return system
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
