import Foundation

/// «Ждали / увидели»: for one of the three services, what must be true when it works, what is there, and whether the two agree. A line
/// that disagrees is the first thing a reader of a report looks for.
struct ServiceCheck: Equatable {
    let name: String
    let expected: String
    let seen: String
    let agrees: Bool

    var lines: [String] {
        [name, "  ждали: \(expected)", "  увидели: \(seen)", "  итог: \(agrees ? "совпало" : "РАСХОДИТСЯ")"]
    }
}

/// What the system looks like right now, as far as the report needs it. Asked of the system off the main thread, then read by the builders.
struct SystemSnapshot {
    /// The section «Сеть», as lines.
    var lines: [String] = []
    /// The interface that the route to the internet uses ("en0", "utun5").
    var interface = "?"
    /// `warp=` of the answer of Cloudflare ("on", "off", "plus"); nil when it did not answer.
    var warp: String?
    /// The DNS servers set on each network connection (empty: automatic).
    var serviceServers: [[String]] = []
    /// The servers that the system really asks, from `scutil --dns`.
    var resolver: [String] = []
    /// The routes of the tunnel in its state file.
    var routes = 0
    /// The WARP server the tunnel is connected to (its state file).
    var tunnelServer: String?
    /// What the helper wrote when it took the tunnel down itself, if that was lately.
    var dropped: String?
    /// The restarts of the tunnel program by the helper in the last day.
    var restarts: [Date] = []
    /// The last lines of the log of the tunnel daemon (empty: no log).
    var daemonLog: [String] = []
    var proxies: [String] = []
    var hostsMentions: [String] = []
    var vpnConnected = 0
}

enum ReportChecks {
    private static let restartStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func dns(active: DNSProvider?, serviceServers: [[String]], resolver: [String]) -> ServiceCheck {
        let name = "Нейросети (DNS)"
        let total = serviceServers.count
        guard let provider = active else {
            let ours = serviceServers.filter { servers in DNSProvider.all.contains { $0.matches(servers) } }.count
            return ServiceCheck(
                name: name, expected: "выключено: DNS сервисов Nimb нигде не задан",
                seen: ours == 0 ? "DNS сервисов Nimb нигде не задан" : "DNS сервиса Nimb ещё стоит на \(ours) из \(total) подключений",
                agrees: ours == 0)
        }
        let set = serviceServers.filter(provider.matches).count
        let asks = resolver.contains(where: provider.allAddresses.contains)
        return ServiceCheck(
            name: name, expected: "\(provider.name) на всех подключениях, и система спрашивает именно его",
            seen: "\(provider.name) задан на \(set) из \(total) подключений; система спрашивает: \(resolver.isEmpty ? "не удалось узнать" : resolver.joined(separator: ", "))",
            agrees: total > 0 && set == total && asks)
    }

    static func telegram(running: Bool, port: UInt16, listening: Bool, stats: TelegramProxyStats) -> ServiceCheck {
        let name = "Telegram (прокси)"
        guard running else {
            return ServiceCheck(name: name, expected: "выключен: порт никто не слушает",
                                seen: listening ? "выключен, но порт слушается" : "выключен, порт свободен", agrees: !listening)
        }
        let total = stats.totalConnections
        var seen = "порт \(port) \(listening ? "слушает" : "не слушает"); соединений \(total), ошибок \(stats.failures), чужой ключ \(stats.wrongSecret), через WebSocket \(stats.webSocket), напрямую \(stats.directTCP)"
        if total == 0 { seen += " (Telegram ещё не подключался)" }
        return ServiceCheck(name: name, expected: "порт \(port) слушает, Telegram подключается",
                            seen: seen, agrees: listening && stats.wrongSecret == 0)
    }

    static func tunnel(on: Bool, routes: Int, interface: String, warp: String?, dropped: String?, restarts: [Date] = []) -> ServiceCheck {
        let name = "YouTube и Discord (туннель)"
        let viaTunnel = interface.hasPrefix("utun")
        let cloudflare = warp.map { "warp=\($0)" } ?? "Cloudflare не ответил"
        var seen = "маршрутов туннеля \(routes); трафик в интернет идёт через \(interface); \(cloudflare)"
        if let last = restarts.last {
            seen += "; программа туннеля сама останавливалась и запускалась снова за сутки: \(restarts.count) (последний раз в \(restartStamp.string(from: last)))"
        }
        if on {
            return ServiceCheck(name: name, expected: "маршруты туннеля стоят, трафик идёт через него, Cloudflare видит WARP (warp=on)",
                                seen: seen, agrees: routes > 0 && viaTunnel && warp == "on")
        }
        if let dropped { seen += "; туннель остановился сам (\(dropped))" }
        return ServiceCheck(name: name, expected: "выключен: маршрутов туннеля нет, трафик идёт напрямую (warp=off)",
                            seen: seen, agrees: routes == 0 && !viaTunnel && warp != "on")
    }

    /// The last `limit` non-empty lines of the log of the tunnel daemon; where the daemon wrote nothing there is a word about it.
    static func logTail(_ text: String, limit: Int = 25) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? ["пусто"] : Array(lines.suffix(limit))
    }

    // MARK: What may be in the way

    /// The kinds of proxy that are switched on in the output of `scutil --proxy` (only the kinds: the addresses are not the report's business).
    static func proxies(from output: String) -> [String] {
        let kinds = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"), ("ProxyAutoConfigEnable", "PAC")]
        return kinds.compactMap { key, name in
            output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "") == "\(key):1" } ? name : nil
        }
    }

    /// Which of `domains` have a line of their own in the hosts file (not a comment).
    static func hostsMentions(in hosts: String, domains: [String]) -> [String] {
        let lines = hosts.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        return domains.filter { domain in lines.contains { $0.contains(domain) } }
    }

    /// How many VPN connections `scutil --nc list` shows as connected.
    static func connectedVPNs(from output: String) -> Int {
        output.split(separator: "\n").filter { $0.contains("(Connected)") }.count
    }

    static func interference(_ system: SystemSnapshot) -> [String] {
        [
            "Системный прокси: \(system.proxies.isEmpty ? "не включён" : system.proxies.joined(separator: ", "))",
            "Включённых VPN: \(system.vpnConnected)",
            "Записи про нейросети и Telegram в /etc/hosts: \(system.hostsMentions.isEmpty ? "нет" : system.hostsMentions.joined(separator: ", "))",
        ]
    }
}

/// The events of the last day, made out of the lines of the diary: the states of the services, the errors, the new versions. The checks for
/// updates that found nothing are left out (there is one every ten minutes), so are the moments «in work», and a line that comes again and
/// again is told once, with a count.
enum ReportChronology {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let shown: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private struct Event {
        let date: Date
        let tag: String
        let message: String
    }

    private static func parse(_ line: String) -> Event? {
        guard line.count > 24, let date = stamp.date(from: String(line.prefix(19))) else { return nil }
        let rest = line.dropFirst(20)
        guard rest.hasPrefix("["), let close = rest.firstIndex(of: "]") else { return nil }
        let tag = String(rest[rest.index(after: rest.startIndex)..<close])
        return Event(date: date, tag: tag, message: String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isNews(_ event: Event) -> Bool {
        // «working(…)» is the moment between a click and its end: the end is in the next line.
        if event.message.contains("working(") { return false }
        guard event.tag == "update" else { return true }
        return event.message.contains("есть новая версия") || event.message.contains("не удалась")
    }

    static func events(from lines: [String], now: Date, within: TimeInterval = 24 * 3600, limit: Int = 40) -> [String] {
        var collapsed: [(event: Event, count: Int)] = []
        for event in lines.compactMap(parse) where now.timeIntervalSince(event.date) <= within && isNews(event) {
            if let last = collapsed.last, last.event.tag == event.tag, last.event.message == event.message {
                collapsed[collapsed.count - 1].count += 1
            } else {
                collapsed.append((event, 1))
            }
        }
        let out = collapsed.suffix(limit).map { item in
            "\(shown.string(from: item.event.date)) [\(item.event.tag)] \(item.event.message)" + (item.count > 1 ? " (×\(item.count))" : "")
        }
        return out.isEmpty ? ["за последние сутки событий нет"] : out
    }
}
