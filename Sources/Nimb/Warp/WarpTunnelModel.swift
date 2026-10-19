import AppKit
import Foundation

/// Where the helper lives. The directory belongs to root, so a program running as the user cannot swap what runs as root.
enum WarpPaths {
    static let dir = "/usr/local/libexec/nimb"
    static let helper = "\(dir)/nimb-tunnel"
    static let binary = "\(dir)/amneziawg-go"
    static let config = "\(dir)/warp.conf"
    static let stateFile = "/var/run/nimb-tunnel.state"

    /// Settings and helper are in place (the config itself is readable by root only, so only its presence is checked).
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helper) && FileManager.default.fileExists(atPath: config)
    }

    /// Stops the tunnel and deletes everything that was installed. Used by "remove" and by the uninstall.
    static let removeScript = "[ ! -x '\(helper)' ] || { '\(helper)' down; '\(helper)' unregister || true; }; /bin/rm -rf '\(dir)' /var/run/nimb-tunnel.state /var/run/nimb-tunnel.log /var/run/nimb-tunnel.name"
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

    struct SiteCheck: Identifiable, Equatable {
        let name: String
        var result: String
        var ok: Bool
        var id: String { name }
    }

    @Published private(set) var phase: Phase = .off
    @Published var errorMessage: String?
    @Published private(set) var checks: [SiteCheck] = []
    @Published private(set) var isChecking = false

    private var timer: Timer?

    init() {
        refresh()
    }

    var isOn: Bool { if case .on = phase { return true } else { return false } }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }
    var isInstalled: Bool { phase != .notInstalled && phase != .unavailable }

    /// The helper and the daemon travel inside the app; a build without them cannot offer the tunnel.
    private var bundledFiles: (binary: URL, helper: URL)? {
        guard let binary = Bundle.main.url(forResource: "amneziawg-go", withExtension: nil),
              let helper = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh") else { return nil }
        return (binary, helper)
    }

    func refresh() {
        if isWorking { return }
        if bundledFiles == nil && !WarpPaths.isInstalled { phase = .unavailable; return }
        guard WarpPaths.isInstalled else { phase = .notInstalled; return }
        if let interface = Self.runningInterface() { phase = .on(interface: interface) } else { phase = .off }
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

    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() { timer?.invalidate(); timer = nil }

    /// The first start on a Mac, with nothing to enter: makes this Mac's own WARP account (keys and address), puts it together
    /// with the shared preset from the app, installs everything and starts the tunnel, all in one password prompt.
    func enable() {
        guard bundledFiles != nil, !isWorking else { return }
        errorMessage = nil
        checks = []
        phase = .working("Создаю личные ключи WARP…")
        Task {
            let account: WarpAccount
            do {
                account = try await WarpRegistration.register()
            } catch {
                errorMessage = error.localizedDescription
                phase = .off
                refresh()
                return
            }
            phase = .working("Включаю…")
            let outcome = await Task.detached { Result { try Self.installFiles(configText: account.file, thenStart: true) } }.value
            if case .failure(let error) = outcome {
                if case DNSError.cancelled = error {} else { errorMessage = error.localizedDescription }
                // Not installed (the password was refused, say): the account would be left without an owner.
                if !WarpPaths.isInstalled { await WarpRegistration.delete(account) }
            }
            phase = .off
            refresh()
        }
    }

    /// Puts helper, daemon and settings in place as root and, if asked, starts the tunnel in the same prompt.
    nonisolated private static func installFiles(configText: String, thenStart: Bool = true) throws {
        guard let binary = Bundle.main.url(forResource: "amneziawg-go", withExtension: nil),
              let helper = Bundle.main.url(forResource: "nimb-tunnel", withExtension: "sh") else {
            throw WarpConfigError("В этой сборке Nimb нет amneziawg-go.")
        }
        // Staged in the user's temporary folder: root cannot read the app itself if it sits in Desktop or Documents.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-warp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: binary, to: stage.appendingPathComponent("amneziawg-go"))
        try FileManager.default.copyItem(at: helper, to: stage.appendingPathComponent("nimb-tunnel"))
        try Data(configText.utf8).write(to: stage.appendingPathComponent("warp.conf"), options: .atomic)
        let s = "'\(stage.path)'"
        let d = "'\(WarpPaths.dir)'"
        var steps = [
            "set -e",
            // The old settings may hold an account of this Mac; it goes away together with them.
            "if [ -x '\(WarpPaths.helper)' ]; then '\(WarpPaths.helper)' down || true; '\(WarpPaths.helper)' unregister || true; fi",
            "/bin/mkdir -p \(d)", "/usr/sbin/chown root:wheel \(d)", "/bin/chmod 755 \(d)",
            "/usr/bin/install -m 755 -o root -g wheel \(s)/amneziawg-go \(d)/amneziawg-go",
            "/usr/bin/install -m 755 -o root -g wheel \(s)/nimb-tunnel \(d)/nimb-tunnel",
            "/usr/bin/install -m 600 -o root -g wheel \(s)/warp.conf \(d)/warp.conf",
            "/usr/bin/xattr -cr \(d) 2>/dev/null || true",
        ]
        if thenStart { steps.append("'\(WarpPaths.helper)' up") }
        _ = try DNSManager.runPrivileged(steps.joined(separator: "; "))
    }

    /// Stops the tunnel and deletes the helper and the settings (password prompt).
    func remove() {
        errorMessage = nil
        phase = .working("Удаляю…")
        Task.detached {
            let result = Result { try DNSManager.runPrivileged(WarpPaths.removeScript) }
            await MainActor.run {
                if case .failure(let error) = result, case DNSError.cancelled = error {} else if case .failure(let error) = result {
                    self.errorMessage = error.localizedDescription
                }
                self.checks = []
                self.phase = .off
                self.refresh()
            }
        }
    }

    // MARK: On and off

    func toggle() { isOn ? disconnect() : connect() }

    /// The number in the first lines of a helper script ("# nimb-tunnel 2: ...").
    private static func helperVersion(at path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let range = text.range(of: #"# nimb-tunnel (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropFirst("# nimb-tunnel ".count))
    }

    /// The installed helper is older than the one inside this app (after an update of Nimb): it is replaced together with
    /// the start, in the same password prompt. The settings are left as they are.
    private var upgrade: (binary: URL, helper: URL)? {
        guard let files = bundledFiles,
              let bundled = Self.helperVersion(at: files.helper.path),
              (Self.helperVersion(at: WarpPaths.helper) ?? 0) < bundled else { return nil }
        return files
    }

    func connect() {
        guard isInstalled, !isWorking else { return }
        errorMessage = nil
        checks = []
        phase = .working("Включаю…")
        let upgrade = upgrade
        Task.detached {
            let result = Result<String, Error> {
                var script = "'\(WarpPaths.helper)' up"
                var stage: URL?
                defer { if let stage { try? FileManager.default.removeItem(at: stage) } }
                if let upgrade {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-warp-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    stage = folder
                    try FileManager.default.copyItem(at: upgrade.binary, to: folder.appendingPathComponent("amneziawg-go"))
                    try FileManager.default.copyItem(at: upgrade.helper, to: folder.appendingPathComponent("nimb-tunnel"))
                    script = [
                        "set -e",
                        "/usr/bin/install -m 755 -o root -g wheel '\(folder.path)/amneziawg-go' '\(WarpPaths.binary)'",
                        "/usr/bin/install -m 755 -o root -g wheel '\(folder.path)/nimb-tunnel' '\(WarpPaths.helper)'",
                        "/usr/bin/xattr -c '\(WarpPaths.binary)' '\(WarpPaths.helper)' 2>/dev/null || true",
                        script,
                    ].joined(separator: "; ")
                }
                return try DNSManager.runPrivileged(script)
            }
            await MainActor.run {
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = error.localizedDescription }
                }
                self.phase = .off
                self.refresh()
            }
        }
    }

    func disconnect() {
        guard !isWorking else { return }
        errorMessage = nil
        checks = []
        phase = .working("Выключаю…")
        Task.detached {
            let result = Result { try DNSManager.runPrivileged("'\(WarpPaths.helper)' down") }
            await MainActor.run {
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = error.localizedDescription }
                }
                self.phase = .off
                self.refresh()
            }
        }
    }

    // MARK: Check

    /// Asks YouTube and Discord for a tiny answer and shows whether they came.
    func runChecks() {
        guard !isChecking else { return }
        isChecking = true
        Task.detached {
            let targets: [(String, String, Set<Int>)] = [
                ("YouTube", "https://www.youtube.com/generate_204", [204]),
                ("Discord", "https://discord.com/api/v9/gateway", [200]),
            ]
            var results: [SiteCheck] = []
            for (name, url, good) in targets {
                results.append(Self.check(name: name, url: url, good: good))
            }
            let final = results
            await MainActor.run {
                self.checks = final
                self.isChecking = false
            }
        }
    }

    nonisolated private static func check(name: String, url: String, good: Set<Int>) -> SiteCheck {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-o", "/dev/null", "-m", "10", "--connect-timeout", "6", "-w", "%{http_code} %{time_total}", url]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return SiteCheck(name: name, result: "не удалось проверить", ok: false) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        let fields = String(decoding: data, as: UTF8.self).split(separator: " ")
        guard fields.count == 2, let code = Int(fields[0]), code != 0 else { return SiteCheck(name: name, result: "не отвечает", ok: false) }
        let seconds = Double(fields[1]).map { String(format: "%.1f с", $0) } ?? ""
        return good.contains(code) ? SiteCheck(name: name, result: "открывается \(seconds)", ok: true) : SiteCheck(name: name, result: "ответ \(code)", ok: false)
    }
}
