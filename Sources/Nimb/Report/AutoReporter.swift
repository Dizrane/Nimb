import Combine
import Foundation

/// The rules of «Помогать тестированию» that need no program around them: what counts as a fault and how often a report may go.
enum AutoReportRules {
    /// The proxy of Telegram does what it should: it listens while it is on and does not listen while it is off, and not more than a fifth of
    /// its connections fail. (A key that is not ours is the person's business with Telegram, not a fault.)
    static func telegramAgrees(running: Bool, listening: Bool, stats: TelegramProxyStats) -> Bool {
        running ? listening && stats.failures * 5 <= stats.totalConnections : !listening
    }

    /// The tunnel is as the program thinks: when it is on, it has its routes and the traffic goes through it; when it is off, neither.
    static func tunnelAgrees(on: Bool, routes: Int, viaTunnel: Bool) -> Bool {
        on ? routes > 0 && viaTunnel : routes == 0 && !viaTunnel
    }
}

/// Why a report went by itself.
enum AutoTrigger: Equatable {
    case previousEndedBadly
    case tunnelRestarted
    case tunnelDropped
    case mismatch(String)
    case error(String)
    case updateCheck

    /// The same cause has the same key: the key is what is not repeated.
    var key: String {
        switch self {
        case .previousEndedBadly: "crash"
        case .tunnelRestarted: "tunnel-restarted"
        case .tunnelDropped: "tunnel-dropped"
        case .mismatch(let service): "mismatch:\(service)"
        case .error(let service): "error:\(service)"
        case .updateCheck: "update-check"
        }
    }

    /// The words of the head of the report.
    var title: String {
        switch self {
        case .previousEndedBadly: "прошлый запуск закончился неожиданно"
        case .tunnelRestarted: "программа туннеля остановилась сама и была запущена снова"
        case .tunnelDropped: "туннель остановился сам и не запустился снова"
        case .mismatch(let service): "«\(service)» работает не так, как должен, больше 10 минут"
        case .error(let service): "ошибка при работе с «\(service)»"
        case .updateCheck: "проверка обновлений не удаётся несколько раз подряд"
        }
    }
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

    static func allows(key: String, now: Date, history: [Sent]) -> Bool {
        if history.contains(where: { $0.key == key && now.timeIntervalSince($0.at) < samePause }) { return false }
        if history.filter({ now.timeIntervalSince($0.at) < 3600 }).count >= perHour { return false }
        return history.filter { now.timeIntervalSince($0.at) < 24 * 3600 }.count < perDay
    }

    /// Only the last day is kept.
    static func pruned(_ history: [Sent], now: Date) -> [Sent] { history.filter { now.timeIntervalSince($0.at) < 24 * 3600 } }
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
        dns.$errorMessage.compactMap { $0 }.sink { [weak self] _ in self?.notify(.error("нейросети")) }.store(in: &cancellables)
        telegram.$errorMessage.compactMap { $0 }.sink { [weak self] _ in self?.notify(.error("Telegram")) }.store(in: &cancellables)
        warp.$errorMessage.compactMap { $0 }.filter { !$0.hasPrefix("Туннель остановился") && !$0.hasPrefix("Туннель выключился") }
            .sink { [weak self] _ in self?.notify(.error("YouTube и Discord")) }.store(in: &cancellables)
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
            AppLog.shared.add("тестирование", "включено: отчёты при сбоях отправляются сами")
        } else {
            for key in [Self.installKey, Self.historyKey, Self.countKey, Self.lastKey] { defaults.removeObject(forKey: key) }
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
        if tracker.observe("нейросети", agrees: facts.dnsAgrees) { notify(.mismatch("нейросети")) }
        if tracker.observe("Telegram", agrees: facts.telegramAgrees) { notify(.mismatch("Telegram")) }
        if tracker.observe("YouTube и Discord", agrees: facts.tunnelAgrees) { notify(.mismatch("YouTube и Discord")) }
    }

    func notify(_ trigger: AutoTrigger) {
        guard enabled, let dns, let telegram, let warp else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        var history = ((try? JSONDecoder().decode([AutoReportPolicy.Sent].self, from: defaults.data(forKey: Self.historyKey) ?? Data())) ?? [])
        history = AutoReportPolicy.pruned(history, now: now)
        guard AutoReportPolicy.allows(key: trigger.key, now: now, history: history) else { return }
        // Written down before the sending: a second cause in the same moment does not make a second report, and a failed sending is not repeated.
        history.append(AutoReportPolicy.Sent(key: trigger.key, at: now))
        defaults.set(try? JSONEncoder().encode(history), forKey: Self.historyKey)
        let install = defaults.string(forKey: Self.installKey) ?? Self.newInstallID()
        Task {
            let facts = await DiagnosticReport.collect(dns: dns, telegram: telegram, warp: warp)
            let id = DiagnosticReport.newID()
            let text = DiagnosticReport.head(id: id, description: "авто: \(trigger.title) (установка \(install))", contact: "") + "\n\n" + facts
            do {
                try await ReportSender.send(id: id, text: text, auto: (trigger: trigger.key, install: install))
                sentCount += 1
                lastSent = Date()
                defaults.set(sentCount, forKey: Self.countKey)
                defaults.set(lastSent?.timeIntervalSince1970 ?? 0, forKey: Self.lastKey)
                AppLog.shared.add("тестирование", "отчёт \(id) отправлен: \(trigger.title)")
            } catch {
                AppLog.shared.add("тестирование", "отчёт \(id) не отправлен: \(error.localizedDescription)")
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
