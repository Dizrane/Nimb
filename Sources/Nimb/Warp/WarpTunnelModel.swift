import AppKit
import Foundation
import Network

/// The terms a person agrees to by turning WARP on.
enum WarpTerms {
    static let url = URL(string: "https://www.cloudflare.com/application/terms/") ?? URL(fileURLWithPath: "/")
}

/// Where the helper lives. The directory belongs to root, so a program running as the user cannot swap what runs as root.
enum WarpPaths {
    static let dir = "/usr/local/libexec/nimb"
    static let helper = "\(dir)/nimb-tunnel"
    static let binary = "\(dir)/amneziawg-go"
    static let config = "\(dir)/warp.conf"
    static let stateFile = "/var/run/nimb-tunnel.state"
    /// The note the helper leaves when it takes the tunnel down itself (the server stopped answering).
    static let droppedFile = "/var/run/nimb-tunnel.dropped"
    static let daemonLog = "/var/run/nimb-tunnel.log"
    /// The helper starts the program of the tunnel again when it ends by itself: each restart is a unix time on a line of `restartsFile`, and
    /// `restartingFile` is there while one is going on.
    static let restartsFile = "/var/run/nimb-tunnel.restarts"
    static let restartingFile = "/var/run/nimb-tunnel.restarting"
    /// The sudoers rule that lets the person start and stop the tunnel without a password (opt-in, like the one for DNS).
    static let sudoersPath = "/etc/sudoers.d/nimb-tunnel"
    static let passwordlessCommands = ["\(helper) up", "\(helper) down"]

    /// Settings and helper are in place (the config itself is readable by root only, so only its presence is checked).
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helper) && FileManager.default.fileExists(atPath: config)
    }

    /// Stops the tunnel and deletes everything that was installed. Used by "remove" and by the uninstall.
    static let removeScript = "[ ! -x '\(helper)' ] || { '\(helper)' down; '\(helper)' unregister || true; }; /bin/rm -f '\(sudoersPath)'; /bin/rm -rf '\(dir)' /var/run/nimb-tunnel.state /var/run/nimb-tunnel.log /var/run/nimb-tunnel.name /var/run/nimb-tunnel.dropped /var/run/nimb-tunnel.restarts /var/run/nimb-tunnel.restarting /var/run/nimb-tunnel.stopped"
}

/// The tunnel ended without the person: the program of the tunnel exited by itself (`daemon-exited`; an older helper also wrote
/// `no-handshake` when it switched the tunnel off for a silent server). The helper writes "<unix time> <reason>" in `WarpPaths.droppedFile`
/// and has already taken the routes out, so the internet is as it was; the person is told once.
enum TunnelDrop {
    /// A note older than this is history, not news (the file stays until the next start of the tunnel or a restart of the Mac).
    static let newsFor: TimeInterval = 24 * 3600

    static func message(for reason: String) -> String {
        if reason == "no-handshake" {
            return "Туннель выключился сам: Cloudflare не отвечал несколько минут. Интернет снова работает как обычно. Когда связь вернётся, включите туннель ещё раз."
        }
        return "Туннель остановился сам: его программа неожиданно завершилась. Интернет работает как обычно. Включите туннель ещё раз."
    }

    static func parse(_ text: String) -> (when: Date, reason: String)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, let seconds = TimeInterval(first), seconds > 0 else { return nil }
        return (Date(timeIntervalSince1970: seconds), parts.count > 1 ? parts[1] : "")
    }

    /// Whether this note has not been told yet and is recent. `seen` is the time of the last note that was told, as unix seconds.
    static func isNews(_ when: Date, seen: TimeInterval, now: Date) -> Bool {
        when.timeIntervalSince1970 > seen && now.timeIntervalSince(when) < newsFor
    }
}

/// The program of the tunnel ended by itself and the helper started it again (`WarpPaths.restartsFile`). The person is not told: the switch
/// stays on, the tunnel works; the restarts go to the diary and the report, so that a problem behind them can be seen.
enum TunnelRestart {
    /// The mark of a restart in progress is believed for this long: a helper that died in the middle must not keep the switch on for ever.
    static let markerLife: TimeInterval = 120

    static func isActive(markedAt: Date, now: Date) -> Bool { now.timeIntervalSince(markedAt) < markerLife }

    static func parse(_ text: String) -> [Date] {
        text.split(whereSeparator: \.isNewline).compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.map { Date(timeIntervalSince1970: $0) }
    }

    /// The restarts of the last `within` seconds, oldest first.
    static func recent(_ text: String, now: Date, within: TimeInterval = 24 * 3600) -> [Date] {
        parse(text).filter { now.timeIntervalSince($0) < within }.sorted()
    }

    /// The restarts that the diary has not got yet; `seen` is the time of the last one that it has, as unix seconds.
    static func unseen(_ text: String, seen: TimeInterval, now: Date) -> [Date] {
        recent(text, now: now).filter { $0.timeIntervalSince1970 > seen }
    }
}

/// The tunnel does not survive a restart of the Mac (its program ends with it). Like the proxy of Telegram, it remembers that it was on and
/// is started again after the person has logged in: without a password if they have allowed it, otherwise with the usual prompt (a cancelled
/// prompt means «не сейчас»: it is not asked again at the next login).
enum TunnelRestore {
    static let attempts = 3
    static let pause: TimeInterval = 20

    static func shouldRestore(wanted: Bool, installed: Bool, isOff: Bool) -> Bool { wanted && installed && isOff }

    /// A start that failed with a message (no answer from Cloudflare, the network was not up yet) is tried again; a start that failed with no
    /// message was cancelled by the person (the password prompt), and that is the end.
    static func triesAgain(message: String?, attempt: Int) -> Bool { message != nil && attempt + 1 < attempts }
}

/// The keys of the tunnel are made again by the program itself, never by a button: when the tunnel did not start twice running because
/// Cloudflare did not answer the handshake, the internet is there, and the person has asked for it (not a start after a login). Once in a
/// day at most: Cloudflare limits the registrations of one address, and a person cannot be left without keys because of a limit.
enum TunnelKeyReset {
    static let failuresNeeded = 2
    static let pause: TimeInterval = 24 * 3600

    /// How many starts in a row have ended with no handshake: it grows with such a failure and starts again from nothing with any other end.
    static func failures(after message: String?, previous: Int) -> Int {
        guard let message, message.contains("рукопожатия") else { return 0 }
        return previous + 1
    }

    static func shouldReset(failures: Int, internetWorks: Bool, lastReset: Date?, now: Date, userAsked: Bool) -> Bool {
        guard userAsked, internetWorks, failures >= failuresNeeded else { return false }
        guard let lastReset else { return true }
        return now.timeIntervalSince(lastReset) >= pause
    }
}

/// The WARP tunnel: AmneziaWG (WireGuard with extra camouflage) to Cloudflare, so that YouTube and Discord open.
@MainActor
final class WarpTunnelModel: ObservableObject {
    enum Phase: Equatable {
        case unavailable
        case notInstalled
        case off
        case working(String)
        case on(interface: String)
    }

    @Published private(set) var phase: Phase = .off { didSet { if phase != oldValue { AppLog.shared.add("tunnel", "состояние: \(phase)") } } }
    @Published var errorMessage: String? { didSet { if let message = errorMessage { AppLog.shared.add("tunnel", "ошибка: \(message)") } } }
    @Published private(set) var checks: [SiteCheck] = []
    @Published private(set) var isChecking = false
    /// sudo lets this person start and stop the tunnel without a password.
    @Published private(set) var passwordless = false
    @Published private(set) var isSettingAccess = false

    private var timer: Timer?
    private static let droppedSeenKey = "tunnelDroppedSeen"
    private static let restartsSeenKey = "tunnelRestartsSeen"
    private static let wantedKey = "tunnelWanted"
    private static let handshakeFailuresKey = "tunnelHandshakeFailures"
    private static let keysResetKey = "tunnelKeysReset"
    /// The person has it on (or it was on when the Mac went down): it comes back after the next login.
    private static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: wantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: wantedKey) }
    }
    private var restoring = false

    init() {
        refresh()
        refreshAccess()
        cleanLeftovers()
        // Not inside the first update of the scenes: changing state then makes SwiftUI abort.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restoreAfterLogin() }
    }

    /// After a restart of the Mac the tunnel that was on is switched on again, as soon as there is a network.
    private func restoreAfterLogin() {
        guard TunnelRestore.shouldRestore(wanted: Self.wanted, installed: isInstalled, isOff: phase == .off), !restoring else { return }
        restoring = true
        AppLog.shared.add("tunnel", "туннель был включён до выключения компьютера: включаю снова")
        Task { @MainActor in
            defer { restoring = false }
            for attempt in 0..<TunnelRestore.attempts {
                guard await Self.waitForNetwork(timeout: 180) else { AppLog.shared.add("tunnel", "сети нет: туннель не включён"); return }
                guard phase == .off else { return }
                connect(userInitiated: false)
                while isWorking { try? await Task.sleep(nanoseconds: 500_000_000) }
                if isOn { return }
                guard TunnelRestore.triesAgain(message: errorMessage, attempt: attempt) else {
                    if errorMessage == nil { Self.wanted = false; AppLog.shared.add("tunnel", "пароль не введён: туннель не включаю, пока вы сами не включите") }
                    return
                }
                errorMessage = nil
                try? await Task.sleep(nanoseconds: UInt64(TunnelRestore.pause * 1_000_000_000))
            }
            AppLog.shared.add("tunnel", "туннель не включился сам: включите вручную")
        }
    }

    /// Waits until the Mac has a network (at most `timeout` seconds).
    nonisolated private static func waitForNetwork(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "nimb.tunnel.network")
        return await withCheckedContinuation { continuation in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { value in
                queue.async {
                    guard !once.done else { return }
                    once.done = true
                    monitor.cancel()
                    continuation.resume(returning: value)
                }
            }
            monitor.pathUpdateHandler = { path in if path.status == .satisfied { finish(true) } }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// A state file with no daemon behind it: the tunnel died without `down` (a crash of the daemon, a kill, an older helper). Its routes
    /// may still send all the traffic of the Mac into an interface that is gone, and then there is no internet. They are taken out.
    private func cleanLeftovers() {
        guard WarpPaths.isInstalled, FileManager.default.fileExists(atPath: WarpPaths.stateFile), Self.runningInterface() == nil else { return }
        AppLog.shared.add("tunnel", "есть файл состояния, но туннеля нет: убираю остатки")
        Task.detached {
            do {
                _ = try DNSManager.runWithoutPassword([WarpPaths.helper, "down"])
                await MainActor.run { AppLog.shared.add("tunnel", "остатки туннеля убраны"); self.refresh() }
            } catch {
                await MainActor.run {
                    AppLog.shared.add("tunnel", "остатки туннеля не убраны: \(error.localizedDescription)")
                    self.errorMessage = "Туннель остановился неожиданно, и интернет мог пропасть. Нажмите «Включить», потом «Выключить»: остатки уберутся."
                }
            }
        }
    }

    var isOn: Bool { if case .on = phase { return true } else { return false } }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    /// While it works: is it being switched on (or set up) and not off?
    var isTurningOn: Bool {
        if case .working(let text) = phase { return !(text.hasPrefix("Выключаю") || text.hasPrefix("Удаляю")) }
        return isOn
    }
    var isInstalled: Bool { phase != .notInstalled && phase != .unavailable }

    /// The helper and the daemon travel inside the app; a build without them cannot offer the tunnel.
    private var bundledFiles: (binary: URL, helper: URL)? {
        guard let binary = Bundle.main.url(forResource: "amneziawg-go", withExtension: nil),
              let helper = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh") else { return nil }
        return (binary, helper)
    }

    /// What the files and the state of the helper say right now.
    private func currentPhase() -> Phase {
        if bundledFiles == nil && !WarpPaths.isInstalled { return .unavailable }
        if !WarpPaths.isInstalled { return .notInstalled }
        if let interface = Self.runningInterface() { return .on(interface: interface) }
        // The helper is starting the program again: the switch stays as it is, it does not blink.
        if case .on = phase, Self.isRestarting { return phase }
        return .off
    }

    /// The helper marks a restart in progress with a file; an old mark is no mark.
    private static var isRestarting: Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: WarpPaths.restartingFile))?[.modificationDate] as? Date else { return false }
        return TunnelRestart.isActive(markedAt: date, now: Date())
    }

    func refresh() {
        if isWorking { return }
        noticeRestarts()
        noticeDrop()
        // Only a change is published: this runs every few seconds, and an unchanged value would redraw every page.
        let next = currentPhase()
        if next != phase { phase = next }
        if case .on = next, !Self.wanted { Self.wanted = true }
    }

    /// The program of the tunnel ended by itself and was started again: only the diary hears of it.
    private func noticeRestarts() {
        guard let text = try? String(contentsOfFile: WarpPaths.restartsFile, encoding: .utf8) else { return }
        let defaults = UserDefaults.standard
        let fresh = TunnelRestart.unseen(text, seen: defaults.double(forKey: Self.restartsSeenKey), now: Date())
        guard let last = fresh.last else { return }
        defaults.set(last.timeIntervalSince1970, forKey: Self.restartsSeenKey)
        AppLog.shared.add("tunnel", "программа туннеля остановилась сама, помощник запустил её снова (раз: \(fresh.count))")
        AutoReporter.shared.notify(.tunnelRestarted)
    }

    /// The tunnel has ended by itself: the person is told once, on the page and in the diary.
    private func noticeDrop() {
        guard let text = try? String(contentsOfFile: WarpPaths.droppedFile, encoding: .utf8), let drop = TunnelDrop.parse(text) else { return }
        let defaults = UserDefaults.standard
        guard TunnelDrop.isNews(drop.when, seen: defaults.double(forKey: Self.droppedSeenKey), now: Date()) else { return }
        defaults.set(drop.when.timeIntervalSince1970, forKey: Self.droppedSeenKey)
        AppLog.shared.add("tunnel", "туннель остановился сам: \(drop.reason)")
        AutoReporter.shared.notify(.tunnelDropped)
        errorMessage = TunnelDrop.message(for: drop.reason)
    }

    private var loggedServer: String?

    /// The helper may have found another WARP server that opens YouTube (see `nimb-tunnel 15`): the diary says which one the tunnel is at.
    private func noticeServer() {
        guard isOn, let text = try? String(contentsOfFile: WarpPaths.stateFile, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("server=") }) else { return }
        let server = String(line.dropFirst("server=".count))
        guard server != loggedServer else { return }
        loggedServer = server
        AppLog.shared.add("tunnel", "сервер WARP: \(server)")
    }

    /// The end of an operation: "working" gives way straight to the real state, with no "off" in between.
    private func finish() {
        let next = currentPhase()
        if next != phase { phase = next }
        noticeServer()
        // What the person did last is what comes back after a restart (the restore itself decides for itself, see `restoreAfterLogin`).
        if !restoring { Self.wanted = isOn }
    }

    /// The interface of a running tunnel, read from the state file the helper keeps (readable by everyone).
    private static func runningInterface() -> String? {
        guard let text = try? String(contentsOfFile: WarpPaths.stateFile, encoding: .utf8) else { return nil }
        var pid: Int32?, interface: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("pid=") { pid = Int32(line.dropFirst(4)) }
            if line.hasPrefix("interface=") { interface = String(line.dropFirst(10)) }
        }
        guard let pid, let interface else { return nil }
        // EPERM means the process exists but belongs to root, which is what is expected here.
        if kill(pid, 0) == 0 || errno == EPERM { return interface }
        return nil
    }

    /// Reads what sudo allows, off the main thread: it starts a process.
    func refreshAccess() {
        Task.detached {
            let allowed = DNSManager.sudoAllows(WarpPaths.passwordlessCommands)
            await MainActor.run { self.passwordless = allowed }
        }
    }

    /// Gives or takes back the right to start and stop the tunnel without a password. The risk is explained first.
    func setPasswordless(_ enable: Bool, confirm: Bool = true) {
        guard !isWorking, !isSettingAccess else { return }
        let user = NSUserName()
        if enable {
            guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
                errorMessage = "Имя пользователя «\(user)» содержит необычные символы, правило для него не создаю."
                return
            }
            if confirm {
                let alert = NSAlert()
                alert.messageText = "Включать туннель без пароля?"
                alert.informativeText = """
                    Nimb добавит правило в \(WarpPaths.sudoersPath). Один раз понадобится пароль администратора.

                    Правило разрешает вашей учётной записи без пароля только две команды помощника Nimb: включить туннель и выключить его. Помощник лежит в папке, куда может писать только администратор, подменить его нельзя.

                    Риск: любая программа, запущенная от вашего имени, сможет включить или выключить туннель без пароля. Забрать разрешение можно в любой момент.
                    """
                alert.addButton(withTitle: "Дать")
                alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        errorMessage = nil
        isSettingAccess = true
        Task.detached {
            let result = Result<Void, Error> {
                if enable {
                    let lines = [
                        "# Nimb: lets \(user) start and stop the WARP tunnel without a password. Remove this file to undo.",
                        "\(user) ALL = (root) NOPASSWD: \(WarpPaths.passwordlessCommands.joined(separator: ", "))",
                    ]
                    try DNSManager.runPrivileged(DNSManager.ruleInstallScript(at: WarpPaths.sudoersPath, lines: lines))
                } else {
                    try DNSManager.runPrivileged("/bin/rm -f '\(WarpPaths.sudoersPath)'")
                }
            }
            let allowed = DNSManager.sudoAllows(WarpPaths.passwordlessCommands)
            await MainActor.run {
                self.isSettingAccess = false
                self.passwordless = allowed
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = Self.friendly(error) }
                } else if enable && !allowed {
                    self.errorMessage = "Правило установлено, но sudo всё равно просит пароль."
                }
            }
        }
    }

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() { timer?.invalidate(); timer = nil }

    /// The first start on a Mac, with nothing to enter: makes this Mac's own WARP account (keys and address), puts it together
    /// with the shared preset from the app, installs everything and starts the tunnel, all in one password prompt.
    func enable(phaseText: String = "Создаю личные ключи WARP…", afterKeyReset: Bool = false) {
        guard bundledFiles != nil, !isWorking else { return }
        errorMessage = nil
        checks = []
        phase = .working(phaseText)
        Task {
            let account: WarpAccount
            do {
                account = try await WarpRegistration.register()
            } catch {
                errorMessage = error.localizedDescription
                if afterKeyReset { AutoReporter.shared.notify(.newKeysFailed) }
                finish()
                return
            }
            phase = .working("Включаю…")
            let outcome = await Task.detached { Result { try Self.installFiles(configText: account.file, thenStart: true) } }.value
            if case .failure(let error) = outcome {
                if case DNSError.cancelled = error {} else {
                    errorMessage = Self.friendly(error)
                    // New keys were made and the tunnel still does not start: the last way out of the program is gone, and it is told.
                    if afterKeyReset { AutoReporter.shared.notify(.newKeysFailed) }
                }
                // Not installed (the password was refused, say): the account would be left without an owner.
                if !WarpPaths.isInstalled { await WarpRegistration.delete(account) }
            }
            finish()
        }
    }

    /// Puts helper, daemon and settings in place as root and, if asked, starts the tunnel in the same prompt.
    nonisolated private static func installFiles(configText: String, thenStart: Bool = true) throws {
        guard let binary = Bundle.main.url(forResource: "amneziawg-go", withExtension: nil),
              let helper = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh") else {
            throw WarpConfigError("В этой сборке Nimb нет amneziawg-go.")
        }
        // Root checks the staged files before it installs any of them (see `StagedFiles`).
        let staged = try StagedFiles([
            ("amneziawg-go", try Data(contentsOf: binary)),
            ("nimb-tunnel", try Data(contentsOf: helper)),
            ("warp.conf", Data(configText.utf8)),
        ])
        defer { staged.remove() }
        let d = "'\(WarpPaths.dir)'"
        var steps = ["set -e"] + staged.guardedCopy() + [
            // The old settings may hold an account of this Mac; it goes away together with them.
            "if [ -x '\(WarpPaths.helper)' ]; then '\(WarpPaths.helper)' down || true; '\(WarpPaths.helper)' unregister || true; fi",
            "/bin/mkdir -p \(d)", "/usr/sbin/chown root:wheel \(d)", "/bin/chmod 755 \(d)",
            "/usr/bin/install -m 755 -o root -g wheel \"$stage/amneziawg-go\" \(d)/amneziawg-go",
            "/usr/bin/install -m 755 -o root -g wheel \"$stage/nimb-tunnel\" \(d)/nimb-tunnel",
            "/usr/bin/install -m 600 -o root -g wheel \"$stage/warp.conf\" \(d)/warp.conf",
            "/usr/bin/xattr -cr \(d) 2>/dev/null || true",
        ]
        if thenStart { steps.append("'\(WarpPaths.helper)' up") }
        _ = try DNSManager.runPrivileged(steps.joined(separator: "; "))
    }

    // MARK: On and off

    func toggle() { isOn ? disconnect() : connect() }

    /// What the person sees for a failure: the helper's words, and for the common one (no answer from Cloudflare) what to try.
    nonisolated static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        guard text.contains("рукопожатия") else { return text }
        return text + ". Проверьте интернет и попробуйте ещё раз. Если не помогает, при следующей попытке Nimb сам создаст новые ключи. В некоторых сетях Cloudflare закрыт, тогда поможет другая сеть."
    }

    /// The number in the first lines of a helper script ("# nimb-tunnel 2: ...").
    nonisolated private static func helperVersion(at path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let range = text.range(of: #"# nimb-tunnel (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst("# nimb-tunnel ".count))
    }

    /// The versions of the helper: the one installed in the folder of root and the one inside this app (a report asks).
    nonisolated static func helperVersions() -> (installed: Int?, bundled: Int?) {
        let bundled = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh").flatMap { helperVersion(at: $0.path) }
        return (helperVersion(at: WarpPaths.helper), bundled)
    }

    /// The installed helper is older than the one inside this app (after an update of Nimb): it is replaced together with
    /// the start, in the same password prompt. The settings are left as they are.
    private var upgrade: (binary: URL, helper: URL)? {
        guard let files = bundledFiles,
              let bundled = Self.helperVersion(at: files.helper.path),
              (Self.helperVersion(at: WarpPaths.helper) ?? 0) < bundled else { return nil }
        return files
    }

    /// Starting (or stopping) the tunnel goes to the password prompt at once. The very first start does not count: it asks Cloudflare for
    /// the keys of this Mac first, and the prompt comes some seconds later.
    func asksPassword(turningOn: Bool) -> Bool {
        guard phase == .off || isOn else { return false }
        return !passwordless || (turningOn && upgrade != nil)
    }

    func connect(userInitiated: Bool = true) {
        guard isInstalled, !isWorking else { return }
        errorMessage = nil
        checks = []
        let upgrade = upgrade
        // After an update of Nimb the helper in the folder of root is replaced by the new one: that needs the password once, even with the
        // permission «без пароля». The person is told why.
        phase = .working(upgrade != nil && passwordless ? "Обновляю помощник туннеля: пароль нужен один раз…" : "Включаю…")
        let withoutPassword = passwordless && upgrade == nil
        Task.detached {
            let result = Result<String, Error> {
                if withoutPassword { return try Self.runWithoutPassword("up") }
                var script = "'\(WarpPaths.helper)' up"
                var staged: StagedFiles?
                defer { staged?.remove() }
                if let upgrade {
                    let files = try StagedFiles([
                        ("amneziawg-go", try Data(contentsOf: upgrade.binary)),
                        ("nimb-tunnel", try Data(contentsOf: upgrade.helper)),
                    ])
                    staged = files
                    script = (["set -e"] + files.guardedCopy() + [
                        "/usr/bin/install -m 755 -o root -g wheel \"$stage/amneziawg-go\" '\(WarpPaths.binary)'",
                        "/usr/bin/install -m 755 -o root -g wheel \"$stage/nimb-tunnel\" '\(WarpPaths.helper)'",
                        "/usr/bin/xattr -c '\(WarpPaths.binary)' '\(WarpPaths.helper)' 2>/dev/null || true",
                        script,
                    ]).joined(separator: "; ")
                }
                return try DNSManager.runPrivileged(script)
            }
            await MainActor.run {
                var message: String?
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { message = Self.friendly(error); self.errorMessage = message }
                    if case DNSError.cancelled = error { self.finish(); return }
                }
                self.finish()
                self.afterStart(failedWith: message, userAsked: userInitiated)
            }
        }
    }

    /// Counts the starts that ended with no handshake, and makes new keys when it comes to that (see `TunnelKeyReset`).
    private func afterStart(failedWith message: String?, userAsked: Bool) {
        let defaults = UserDefaults.standard
        let failures = TunnelKeyReset.failures(after: message, previous: defaults.integer(forKey: Self.handshakeFailuresKey))
        defaults.set(failures, forKey: Self.handshakeFailuresKey)
        let last = defaults.double(forKey: Self.keysResetKey)
        let lastReset = last > 0 ? Date(timeIntervalSince1970: last) : nil
        guard failures >= TunnelKeyReset.failuresNeeded, userAsked, !isOn, lastReset.map({ Date().timeIntervalSince($0) >= TunnelKeyReset.pause }) ?? true else { return }
        Task {
            // The internet is looked at first: with none, new keys would not help, and Cloudflare would be asked for nothing.
            guard await Self.cloudflareReachable(),
                  TunnelKeyReset.shouldReset(failures: failures, internetWorks: true, lastReset: lastReset, now: Date(), userAsked: userAsked) else { return }
            defaults.set(Date().timeIntervalSince1970, forKey: Self.keysResetKey)
            defaults.set(0, forKey: Self.handshakeFailuresKey)
            AppLog.shared.add("tunnel", "туннель дважды подряд не получил рукопожатие при рабочем интернете: создаю новые ключи")
            enable(phaseText: "Ключи не подошли, создаю новые…", afterKeyReset: true)
        }
    }

    /// Cloudflare answers on the open internet (the tunnel is off then): the network is fine.
    nonisolated static func cloudflareReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!, timeoutInterval: 6)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func disconnect() {
        guard !isWorking else { return }
        errorMessage = nil
        checks = []
        phase = .working("Выключаю…")
        let withoutPassword = passwordless
        Task.detached {
            let result = Result { withoutPassword ? try Self.runWithoutPassword("down") : try DNSManager.runPrivileged("'\(WarpPaths.helper)' down") }
            await MainActor.run {
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = Self.friendly(error) }
                }
                self.finish()
            }
        }
    }

    /// Starts or stops the tunnel through the sudoers rule. If sudo asks for a password after all (the rule is gone or
    /// stale), the usual prompt is used instead.
    nonisolated private static func runWithoutPassword(_ verb: String) throws -> String {
        do {
            return try DNSManager.runWithoutPassword([WarpPaths.helper, verb])
        } catch DNSError.failed(let message) where message.contains("password is required") || message.contains("not allowed") || message.contains("may not run") {
            return try DNSManager.runPrivileged("'\(WarpPaths.helper)' \(verb)")
        }
    }

    // MARK: Check

    /// Asks YouTube and Discord for small answers at several addresses and shows what came.
    func runChecks() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let results = await SiteChecker.run()
            checks = results
            AppLog.shared.add("tunnel", "проверка: " + results.map { "\($0.name) \($0.result)" }.joined(separator: "; "))
            isChecking = false
        }
    }
}
