import Combine
import Foundation

/// The rules of «Помогать тестированию» that need no program around them: what counts as a fault and how often a report may go.
enum AutoReportRules {
    /// The proxy of Telegram does what it should: it listens while it is on and does not listen while it is off. How many of its connections
    /// fail is not counted: it is the network's (a provider that has closed the addresses of Telegram makes nine of ten fail, and nothing in
    /// Nimb can mend that; the manual report still shows the numbers). A key that is not ours is the person's business with Telegram.
    static func telegramAgrees(running: Bool, listening: Bool) -> Bool {
        running ? listening : !listening
    }

    /// The settings are as Nimb set them: its DNS stands on every connection when it is on, and nowhere when it is off. Whom the system really
    /// asks is left out here (another VPN or a browser with its own DNS may take it over, and that is not ours to mend); the manual report shows it.
    static func dnsAgrees(active: DNSProvider?, serviceServers: [[String]]) -> Bool {
        ReportChecks.dns(active: active, serviceServers: serviceServers, resolver: active?.addresses ?? []).agrees
    }

    /// What the count of a disagreement is fed with: a disagreement of the settings while the internet is gone says nothing about Nimb (the
    /// Wi-Fi was lost, another program set the DNS again), so it counts as an agreement until the net answers.
    static func dnsCounts(agrees: Bool, online: Bool) -> Bool { agrees || !online }

    /// The tunnel is as the program thinks: when it is on, it has its routes and the traffic goes through it; when it is off, it has no routes.
    /// (Another VPN that carries the traffic while ours is off is the person's business, not a fault of ours: the report of it is the manual one.)
    static func tunnelAgrees(on: Bool, routes: Int, viaTunnel: Bool) -> Bool {
        on ? routes > 0 && viaTunnel : routes == 0
    }
}

/// The three services, with a name for the key (plain letters: the relay and the tags of Telegram take nothing else) and a name for people.
enum AutoService: String {
    case dns, telegram, tunnel

    var name: String {
        switch self {
        case .dns: "нейросети"
        case .telegram: "Telegram"
        case .tunnel: "YouTube и Discord"
        }
    }
}

/// Why a report went by itself.
enum AutoTrigger: Equatable {
    case previousEndedBadly
    case tunnelRestarted
    case tunnelDropped
    case mismatch(AutoService)
    case error(AutoService)
    case updateCheck
    case tunnelSilent
    case newKeysFailed
    case dailyDigest

    /// The same cause has the same key: the key is what is not repeated.
    var key: String {
        switch self {
        case .previousEndedBadly: "crash"
        case .tunnelRestarted: "tunnel-restarted"
        case .tunnelDropped: "tunnel-dropped"
        case .mismatch(let service): "mismatch-\(service.rawValue)"
        case .error(let service): "error-\(service.rawValue)"
        case .updateCheck: "update-check"
        case .tunnelSilent: "tunnel-silent"
        case .newKeysFailed: "keys-failed"
        case .dailyDigest: "daily"
        }
    }

    /// The words of the head of the report.
    var title: String {
        switch self {
        case .previousEndedBadly: "прошлый запуск закончился неожиданно"
        case .tunnelRestarted: "программа туннеля остановилась сама и была запущена снова"
        case .tunnelDropped: "туннель остановился сам и не запустился снова"
        case .mismatch(let service): "«\(service.name)» работает не так, как должен, больше 10 минут"
        case .error(let service): "ошибка при работе с «\(service.name)»"
        case .updateCheck: "проверка обновлений не удаётся несколько раз подряд"
        case .tunnelSilent: "туннель включён, но сервер не отвечает больше 10 минут"
        case .newKeysFailed: "новые ключи туннеля не помогли: туннель по-прежнему не включается"
        case .dailyDigest: "ежедневная сводка"
        }
    }
}

extension AutoTrigger {
    /// A cause that is told even when another report went within the hour: the one that matters most (what a person's last way out came to).
    var ignoresHourLimit: Bool { self == .newKeysFailed }
}

/// How often a report may go. A report that was sent is written down with its key and its time.
enum AutoReportPolicy {
    struct Sent: Codable, Equatable {
        let key: String
        let at: Date
    }

    /// The same cause is told once in this time.
    static let samePause: TimeInterval = 6 * 3600
    static let perHour = 1
    static let perDay = 5

    static func allows(key: String, now: Date, history: [Sent], ignoresHourLimit: Bool = false) -> Bool {
        if history.contains(where: { $0.key == key && now.timeIntervalSince($0.at) < samePause }) { return false }
        if !ignoresHourLimit && history.filter({ now.timeIntervalSince($0.at) < 3600 }).count >= perHour { return false }
        return history.filter { now.timeIntervalSince($0.at) < 24 * 3600 }.count < perDay
    }

    /// Only the last day is kept.
    static func pruned(_ history: [Sent], now: Date) -> [Sent] { history.filter { now.timeIntervalSince($0.at) < 24 * 3600 } }
}

/// How long ago the server of the tunnel last answered: the daemon writes «Received handshake response» into its log with the time, a
/// healthy tunnel does it every two minutes. A tunnel that is on and silent for longer carries the traffic into nothing.
enum TunnelHandshake {
    static let staleAfter: TimeInterval = 300

    private static let pattern = try? NSRegularExpression(pattern: #"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) .*Received handshake response"#)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    /// Seconds since the last answer in the log; nil when the log has none (it was cut, or the tunnel has just begun).
    static func age(inLog text: String, now: Date) -> Int? {
        guard let pattern else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() where line.contains("Received handshake response") {
            let line = String(line)
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line),
                  let when = stamp.date(from: String(line[range])) else { continue }
            return max(0, Int(now.timeIntervalSince(when)))
        }
        return nil
    }
}

/// A report that could not go (the net was down, which is just when it is wanted) waits and goes at the first chance, for a day at most.
enum PendingReports {
    struct Item: Codable, Equatable {
        let id: String
        let trigger: String
        let install: String
        let text: String
        let at: Date
    }

    static let keepFor: TimeInterval = 24 * 3600
    static let keepCount = 3

    /// The ones that are still worth sending: not older than a day, the latest few.
    static func fresh(_ items: [Item], now: Date) -> [Item] {
        Array(items.filter { now.timeIntervalSince($0.at) < keepFor }.suffix(keepCount))
    }

    static func decode(_ data: Data?) -> [Item] {
        guard let data, let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }
}

/// The report of the day: once in 24 hours, with the small things that are not worth a report of their own. It does not count in the limits
/// above (it is one a day by its own clock), and it carries the numbers of the black box and the causes that were told that day.
enum DailyDigest {
    static let every: TimeInterval = 24 * 3600

    static func isDue(now: Date, last: Date) -> Bool { now.timeIntervalSince(last) >= every }

    /// The day in numbers, from the lines of the black box (see `BlackBoxLine.line`) and the keys of the reports sent in the day.
    static func summary(lines: [String], sentKeys: [String]) -> String {
        var disagreements = ["dns": 0, "telegram": 0, "туннель": 0]
        var memory: [Int] = []
        for line in lines {
            for part in line.components(separatedBy: " | ") {
                if part.contains("совпало=НЕТ"), let name = disagreements.keys.first(where: { part.hasPrefix($0 + "=") }) { disagreements[name, default: 0] += 1 }
                if part.hasPrefix("память="), let value = Int(part.dropFirst("память=".count).dropLast("МБ".count)) { memory.append(value) }
            }
        }
        var out = ["— Сутки в цифрах —", "Записей чёрного ящика: \(lines.count) из \(BlackBoxLine.keepLines)"]
        // The box keeps the last lines, not the last day: the period says what the numbers are about, and the lines say how long it worked.
        if let first = lines.first?.prefix(19), let last = lines.last?.prefix(19) {
            out.append("Период записей: с \(first) по \(last); работы по записям около \(lines.count * 5) мин")
        }
        for name in ["dns", "telegram", "туннель"] { out.append("\(name): не совпало в \(disagreements[name] ?? 0) записях") }
        let silent = lines.filter { line in
            guard let range = line.range(of: "рукопожатие="), let seconds = Int(line[range.upperBound...].prefix { $0.isNumber }) else { return false }
            return Double(seconds) > TunnelHandshake.staleAfter
        }.count
        if silent > 0 { out.append("туннель включён, но сервер не отвечал: в \(silent) записях") }
        if let top = memory.max(), let now = memory.last { out.append("Память: до \(top) МБ, в последней записи \(now) МБ") }
        out.append("Отчётов по сбоям за сутки: \(sentKeys.count)" + (sentKeys.isEmpty ? "" : " (\(sentKeys.joined(separator: ", ")))"))
        return out.joined(separator: "\n")
    }
}

/// «Не так» must last: one look that disagrees is a moment of switching, two in a row (ten minutes) is a fault.
struct MismatchTracker {
    static let looks = 2
    private var streaks: [String: Int] = [:]

    /// Returns true once, when the disagreement of `service` has lasted long enough.
    mutating func observe(_ service: String, agrees: Bool) -> Bool {
        guard !agrees else { streaks[service] = 0; return false }
        streaks[service, default: 0] += 1
        return streaks[service] == Self.looks
    }
}

/// «Помогать тестированию» (off until the person turns it on): when something goes wrong the program sends a report to the developer by
/// itself, the same one that «Сообщить о проблеме» makes, with what the black box has kept. Not on a clock: on a cause, and not oftener
/// than `AutoReportPolicy` allows. The random number of the installation tells repeated reports of one Mac from those of many; turning the
/// switch off wipes it.
@MainActor
final class AutoReporter: ObservableObject {
    static let shared = AutoReporter()

    private static let enabledKey = "helpTesting"
    private static let installKey = "helpTestingInstall"
    private static let historyKey = "helpTestingHistory"
    private static let countKey = "helpTestingCount"
    private static let lastKey = "helpTestingLast"
    private static let digestKey = "helpTestingDigest"
    private static let pendingURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Logs/Nimb/pending-reports.json")
    }()

    @Published private(set) var enabled: Bool
    @Published private(set) var sentCount: Int
    @Published private(set) var lastSent: Date?

    private var dns: DNSViewModel?
    private var telegram: TelegramProxyModel?
    private var warp: WarpTunnelModel?
    private var cancellables: Set<AnyCancellable> = []
    private var tracker = MismatchTracker()

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.enabledKey)
        sentCount = defaults.integer(forKey: Self.countKey)
        let last = defaults.double(forKey: Self.lastKey)
        lastSent = last > 0 ? Date(timeIntervalSince1970: last) : nil
    }

    func configure(dns: DNSViewModel, telegram: TelegramProxyModel, warp: WarpTunnelModel) {
        guard self.dns == nil else { return }
        self.dns = dns; self.telegram = telegram; self.warp = warp
        // An error that the person is shown. The words that are the tunnel's own news (it stopped by itself) have their own trigger.
        dns.$errorMessage.compactMap { $0 }.sink { [weak self] _ in self?.notify(.error(.dns)) }.store(in: &cancellables)
        telegram.$errorMessage.compactMap { $0 }.sink { [weak self] _ in self?.notify(.error(.telegram)) }.store(in: &cancellables)
        warp.$errorMessage.compactMap { $0 }.filter { !$0.hasPrefix("Туннель остановился") && !$0.hasPrefix("Туннель выключился") }
            .sink { [weak self] _ in self?.notify(.error(.tunnel)) }.store(in: &cancellables)
        // The last run ended badly: told a little after the start, when the network is there.
        if SessionMarker.previousEndedBadly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.notify(.previousEndedBadly) }
        }
    }

    // MARK: The switch

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        let defaults = UserDefaults.standard
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            defaults.set(Self.newInstallID(), forKey: Self.installKey)
            // The first digest comes in a day, not at once.
            defaults.set(Date().timeIntervalSince1970, forKey: Self.digestKey)
            AppLog.shared.add("тестирование", "включено: отчёты при сбоях отправляются сами, сводка раз в сутки")
        } else {
            for key in [Self.installKey, Self.historyKey, Self.countKey, Self.lastKey, Self.digestKey] { defaults.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: Self.pendingURL)
            sentCount = 0
            lastSent = nil
            AppLog.shared.add("тестирование", "выключено: номер установки стёрт")
        }
    }

    /// Letters and digits that cannot be mistaken for each other.
    nonisolated static func newInstallID() -> String {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in letters.randomElement() ?? "X" })
    }

    // MARK: Causes

    /// A look of the black box: a service that disagrees with what it should be, for long enough, is a cause.
    func observe(_ facts: BlackBoxLine.Facts) {
        guard enabled else { return }
        observeDNS(agrees: facts.dnsAgrees)
        if tracker.observe("telegram", agrees: facts.telegramAgrees) { notify(.mismatch(.telegram)) }
        if tracker.observe("tunnel", agrees: facts.tunnelAgrees) { notify(.mismatch(.tunnel)) }
        let silent = facts.handshakeSeconds.map { Double($0) > TunnelHandshake.staleAfter } ?? false
        if tracker.observe("handshake", agrees: !silent) { notify(.tunnelSilent) }
        sendDigestIfDue()
        retryPending()
    }

    private var retrying = false

    /// Reports that did not go are tried again at each look of the black box, oldest first, until one fails (the net is still down).
    private func retryPending() {
        guard !retrying else { return }
        let items = PendingReports.fresh(PendingReports.decode(try? Data(contentsOf: Self.pendingURL)), now: Date())
        guard !items.isEmpty else { try? FileManager.default.removeItem(at: Self.pendingURL); return }
        retrying = true
        Task {
            var left = items
            for item in items {
                do {
                    try await ReportSender.send(id: item.id, text: item.text, auto: (trigger: item.trigger, install: item.install))
                    left.removeAll { $0 == item }
                    recordSent()
                    AppLog.shared.add("тестирование", "отчёт \(item.id) отправлен позже, когда сеть вернулась")
                } catch {
                    break
                }
            }
            if left.isEmpty { try? FileManager.default.removeItem(at: Self.pendingURL) } else { try? JSONEncoder().encode(left).write(to: Self.pendingURL) }
            retrying = false
        }
    }

    private func recordSent() {
        sentCount += 1
        lastSent = Date()
        UserDefaults.standard.set(sentCount, forKey: Self.countKey)
        UserDefaults.standard.set(lastSent?.timeIntervalSince1970 ?? 0, forKey: Self.lastKey)
    }

    private func history(now: Date) -> [AutoReportPolicy.Sent] {
        let stored = (try? JSONDecoder().decode([AutoReportPolicy.Sent].self, from: UserDefaults.standard.data(forKey: Self.historyKey) ?? Data())) ?? []
        return AutoReportPolicy.pruned(stored, now: now)
    }

    /// The report of the day goes when a day has passed since the last one (or since the switch was turned on). A Mac that was asleep sends it
    /// at the first look after waking.
    private func sendDigestIfDue() {
        let defaults = UserDefaults.standard
        let now = Date()
        let stamp = defaults.double(forKey: Self.digestKey)
        // Turned on by an older version: the day starts now.
        guard stamp > 0 else { defaults.set(now.timeIntervalSince1970, forKey: Self.digestKey); return }
        guard DailyDigest.isDue(now: now, last: Date(timeIntervalSince1970: stamp)) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.digestKey)
        let summary = DailyDigest.summary(lines: BlackBox.lastLines(BlackBoxLine.keepLines), sentKeys: history(now: now).map(\.key))
        deliver(.dailyDigest, summary: summary)
    }

    /// A disagreement of the DNS is counted only while Cloudflare answers (one small request, and only while there is a disagreement).
    private func observeDNS(agrees: Bool) {
        guard !agrees else { _ = tracker.observe("dns", agrees: true); return }
        Task {
            let online = await WarpTunnelModel.cloudflareReachable()
            if tracker.observe("dns", agrees: AutoReportRules.dnsCounts(agrees: false, online: online)) { notify(.mismatch(.dns)) }
        }
    }

    func notify(_ trigger: AutoTrigger) {
        guard enabled else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        var history = history(now: now)
        guard AutoReportPolicy.allows(key: trigger.key, now: now, history: history, ignoresHourLimit: trigger.ignoresHourLimit) else { return }
        // Written down before the sending: a second cause in the same moment does not make a second report, and a failed sending is not repeated.
        history.append(AutoReportPolicy.Sent(key: trigger.key, at: now))
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
        deliver(trigger, summary: nil)
    }

    private func deliver(_ trigger: AutoTrigger, summary: String?) {
        guard let dns, let telegram, let warp else { return }
        let defaults = UserDefaults.standard
        let install = defaults.string(forKey: Self.installKey) ?? Self.newInstallID()
        Task {
            let facts = await DiagnosticReport.collect(dns: dns, telegram: telegram, warp: warp)
            let id = DiagnosticReport.newID()
            let text = DiagnosticReport.head(id: id, description: "авто: \(trigger.title) (установка \(install))", contact: "") + "\n\n" + (summary.map { $0 + "\n\n" } ?? "") + facts
            do {
                try await ReportSender.send(id: id, text: text, auto: (trigger: trigger.key, install: install))
                recordSent()
                AppLog.shared.add("тестирование", "отчёт \(id) отправлен: \(trigger.title)")
            } catch {
                // Kept for the next looks: the net may be down just because of the fault that is being told.
                let item = PendingReports.Item(id: id, trigger: trigger.key, install: install, text: text, at: Date())
                let kept = PendingReports.fresh(PendingReports.decode(try? Data(contentsOf: Self.pendingURL)) + [item], now: Date())
                try? JSONEncoder().encode(kept).write(to: Self.pendingURL)
                AppLog.shared.add("тестирование", "отчёт \(id) не отправлен, будет ещё попытка: \(error.localizedDescription)")
            }
        }
    }

    /// What a report that goes by itself looks like now (for «Что отправляется»).
    func preview() async -> String {
        guard let dns, let telegram, let warp else { return "" }
        let facts = await DiagnosticReport.collect(dns: dns, telegram: telegram, warp: warp)
        return DiagnosticReport.head(id: "XXXXXX", description: "авто: <причина> (установка \(UserDefaults.standard.string(forKey: Self.installKey) ?? "…"))", contact: "") + "\n\n" + facts
    }

    /// «сегодня в 14:20», «23 октября в 14:20»: when the last one went.
    static func lastWords(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        return Calendar.current.isDate(date, inSameDayAs: now) ? "сегодня в \(time)" : date.formatted(.dateTime.day().month(.wide)) + " в \(time)"
    }
}
