import Foundation

enum DNSError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Запрос пароля отменён."
        case .failed(let message): return message
        }
    }
}

/// Reads and changes DNS servers through the system `networksetup` tool.
enum DNSManager {
    // MARK: Reading (no privileges needed)

    /// Enabled, non-VPN network services (Wi-Fi, Ethernet, ...). VPN pseudo-services have no device.
    static func physicalServices() -> [String] {
        guard let output = try? run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return [] }
        var result: [String] = []
        var current: String?
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), line[line.index(after: line.startIndex)].isNumber {
                // "(1) Wi-Fi" is enabled, "(*) Wi-Fi" would be disabled and fails the isNumber check.
                current = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("(Hardware Port:"), let name = current {
                if let range = line.range(of: "Device: ") {
                    let device = line[range.upperBound...].dropLast().trimmingCharacters(in: .whitespaces)
                    if !device.isEmpty { result.append(name) }
                }
                current = nil
            }
        }
        return result
    }

    static func servers(of service: String) -> [String] {
        guard let output = try? run("/usr/sbin/networksetup", ["-getdnsservers", service]) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { $0.first?.isNumber == true }
    }

    /// The provider currently set on every physical service, or nil if DNS is automatic or mixed.
    static func activeProvider(on services: [String]) -> DNSProvider? {
        guard !services.isEmpty else { return nil }
        return DNSProvider.all.first { provider in
            services.allSatisfy { servers(of: $0) == provider.addresses }
        }
    }

    /// A provider that is set on some, but not all, of the services, with the services it is missing on.
    static func partialProvider(on services: [String]) -> (provider: DNSProvider, missing: [String])? {
        for provider in DNSProvider.all {
            let missing = services.filter { servers(of: $0) != provider.addresses }
            if !missing.isEmpty, missing.count < services.count { return (provider, missing) }
        }
        return nil
    }

    // MARK: Overrides (read-only)

    /// Reasons why the DNS set on the services may not be the one the system actually uses.
    static func overrideWarnings(for provider: DNSProvider) -> [String] {
        var warnings: [String] = []

        if let list = try? run("/usr/sbin/scutil", ["--nc", "list"]) {
            for line in list.split(separator: "\n") where line.contains("(Connected)") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                let name = parts.count >= 3 ? String(parts[1]) : "VPN"
                warnings.append("Включён VPN «\(name)»: он может использовать свой DNS.")
            }
        }

        let resolvers = systemResolvers()
        // A DNS profile or DNS proxy registers itself as a resolver on the loopback address.
        if resolvers.contains(where: { $0.nameservers.contains { $0 == "127.0.0.1" || $0 == "::1" } }) {
            warnings.append("В системе есть локальный DNS-профиль или прокси (127.0.0.1): он может перекрывать выбранный DNS.")
        }
        if let main = resolvers.first(where: { $0.domain == nil && !$0.isSupplemental }),
           !main.nameservers.contains(where: provider.addresses.contains) {
            warnings.append("Системный DNS сейчас \(main.nameservers.joined(separator: ", ")), а не \(provider.name). Вероятно, он не включён на основном подключении.")
        }
        if let browser = BrowserDNS.currentWarning() { warnings.append(browser) }
        return warnings
    }

    /// The servers that the system asks first for an ordinary name: the unscoped resolver without a domain, from `scutil --dns`.
    static func mainResolverServers() -> [String] {
        systemResolvers().first { $0.domain == nil && !$0.isSupplemental }?.nameservers ?? []
    }

    private struct Resolver {
        var domain: String?
        var nameservers: [String] = []
        var isSupplemental = false
    }

    /// Resolvers from the unscoped section of `scutil --dns`.
    private static func systemResolvers() -> [Resolver] {
        guard let output = try? run("/usr/sbin/scutil", ["--dns"]) else { return [] }
        var resolvers: [Resolver] = []
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("DNS configuration (for scoped queries)") { break }
            if line.hasPrefix("resolver #") {
                resolvers.append(Resolver())
            } else if !resolvers.isEmpty, let colon = line.range(of: " : ") {
                let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = String(line[colon.upperBound...])
                if key == "domain" { resolvers[resolvers.count - 1].domain = value }
                if key.hasPrefix("nameserver[") { resolvers[resolvers.count - 1].nameservers.append(value) }
                if key == "flags", value.contains("Supplemental") { resolvers[resolvers.count - 1].isSupplemental = true }
            }
        }
        return resolvers
    }

    // MARK: Writing (asks for the administrator password)

    /// Sets `provider` on all given services, or resets them to automatic DNS when it is nil.
    /// Every command is checked, and the result is read back afterwards.
    static func apply(_ provider: DNSProvider?, to services: [String]) throws {
        if canApplyWithoutPassword(provider, to: services) {
            try applyWithSudo(provider, to: services)
        } else {
            try runPrivileged(applyScript(provider, to: services))
        }

        let expected = provider?.addresses ?? []
        let mismatched = services.filter { servers(of: $0) != expected }
        if !mismatched.isEmpty {
            throw DNSError.failed("DNS не применился на: \(mismatched.joined(separator: ", ")).")
        }
    }

    /// Shell script that runs as root: it tries every command and exits non-zero if any failed.
    /// With `removingRule` the sudoers rule is deleted at the end, but only if every command above succeeded.
    static func applyScript(_ provider: DNSProvider?, to services: [String], removingRule: Bool = false, removingTunnel: Bool = false) -> String {
        let addresses = provider?.addresses.joined(separator: " ") ?? "Empty"
        var script = ["failed=0"]
        for service in services {
            let quoted = shellQuote(service)
            script.append("/usr/sbin/networksetup -setdnsservers \(quoted) \(addresses) || { echo \(shellQuote("Не удалось изменить DNS:")) \(quoted) >&2; failed=1; }")
        }
        script.append("/usr/bin/dscacheutil -flushcache || { echo \(shellQuote("Не удалось сбросить кэш DNS (dscacheutil).")) >&2; failed=1; }")
        script.append("/usr/bin/killall -HUP mDNSResponder || { echo \(shellQuote("Не удалось перезапустить mDNSResponder.")) >&2; failed=1; }")
        if removingRule { script.append("[ $failed -eq 0 ] && /bin/rm -f \(sudoersPath) \(WarpPaths.sudoersPath)") }
        if removingTunnel { script.append("[ $failed -eq 0 ] && { \(WarpPaths.removeScript); }") }
        script.append("exit $failed")
        return script.joined(separator: "; ")
    }

    // MARK: Uninstall

    /// Physical services whose DNS is one of ours. Anything the user set by hand is left alone.
    static func servicesUsingProviders() -> [String] {
        physicalServices().filter { service in
            let current = servers(of: service)
            return DNSProvider.all.contains { $0.addresses == current }
        }
    }

    /// Back to automatic DNS on `services` and, if asked, the sudoers rule removed, in one password prompt.
    static func resetBeforeUninstall(_ services: [String], removingRule: Bool, removingTunnel: Bool = false) throws {
        try runPrivileged(applyScript(nil, to: services, removingRule: removingRule, removingTunnel: removingTunnel))
        let left = services.filter { !servers(of: $0).isEmpty }
        if !left.isEmpty { throw DNSError.failed("DNS не вернулся к автоматическому на: \(left.joined(separator: ", ")).") }
    }

    // MARK: Without a password (opt-in)

    static let sudoersPath = "/etc/sudoers.d/nimb"

    /// What sudo currently allows this user to do without a password, as far as Nimb is concerned.
    struct PasswordlessState: Equatable {
        /// The rule is there for at least one service.
        var enabled = false
        /// Services the rule does not cover (a connection added after it was installed).
        var missing: [String] = []
        /// sudo also lets any DNS address through, not only Nimb's (an old Nimb rule or another sudo rule).
        var tooBroad = false

        var needsUpdate: Bool { enabled && (!missing.isEmpty || tooBroad) }
    }

    /// Services the rule can name: plain characters only, so that nothing in a name can change the meaning of the rule.
    static func isRuleSafe(_ service: String) -> Bool {
        service.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._()+/-]*$"#, options: .regularExpression) != nil
    }

    private static let networksetup = "/usr/sbin/networksetup"

    /// What `sudo -l` lists as allowed without a password. Listing needs no password once any NOPASSWD entry exists,
    /// and `sudo -l <command>` also succeeds for commands that would ask for one, so the list itself is read.
    private struct NoPasswordList {
        var commands: Set<String> = []
        var everything = false

        func allows(_ command: String) -> Bool { everything || commands.contains(command) }
    }

    private static func noPasswordList() -> NoPasswordList {
        guard let output = try? run("/usr/bin/sudo", ["-n", "-l"]) else { return NoPasswordList() }
        var list = NoPasswordList()
        for line in output.split(separator: "\n") {
            guard let marker = line.range(of: "NOPASSWD:") else { continue }
            for entry in line[marker.upperBound...].components(separatedBy: ", ") {
                let command = entry.trimmingCharacters(in: .whitespaces)
                if command == "ALL" { list.everything = true } else if !command.isEmpty { list.commands.insert(command) }
            }
        }
        return list
    }

    /// Whether sudo would set an address that is not Nimb's without a password. The probe names a service that does
    /// not exist, so even if sudo lets it through, networksetup fails and nothing changes.
    private static func sudoAcceptsAnyDNS() -> Bool {
        do {
            _ = try run("/usr/bin/sudo", ["-n", networksetup, "-setdnsservers", "Nimb-probe", "8.8.8.8"])
            return true
        } catch DNSError.failed(let message) {
            return !["password is required", "may not run", "not allowed"].contains { message.contains($0) }
        } catch {
            return false
        }
    }

    private static func setCommand(_ service: String, _ addresses: [String]) -> String {
        "\(networksetup) -setdnsservers \(service) \(addresses.joined(separator: " "))"
    }

    static func passwordlessState(for services: [String]) -> PasswordlessState {
        let named = services.filter(isRuleSafe)
        let list = noPasswordList()
        let covered = named.filter { list.allows(setCommand($0, ["Empty"])) }
        guard !covered.isEmpty else { return PasswordlessState() }
        return PasswordlessState(
            enabled: true,
            missing: named.filter { !covered.contains($0) },
            tooBroad: sudoAcceptsAnyDNS()
        )
    }

    private static func canApplyWithoutPassword(_ provider: DNSProvider?, to services: [String]) -> Bool {
        let addresses = provider?.addresses ?? ["Empty"]
        let list = noPasswordList()
        return !services.isEmpty
            && services.allSatisfy { list.allows(setCommand($0, addresses)) }
            && list.allows("/usr/bin/dscacheutil -flushcache")
            && list.allows("/usr/bin/killall -HUP mDNSResponder")
    }

    /// The sudoers rule: exactly the commands Nimb runs, with its own provider addresses and the services present now.
    /// No wildcards, so a program cannot use it to set some other DNS. Everything else still asks for the password.
    static func sudoersRule(for user: String, services: [String]) -> [String] {
        func escaped(_ service: String) -> String { service.replacingOccurrences(of: " ", with: "\\ ") }
        var commands: [String] = []
        for service in services {
            for addresses in [["Empty"]] + DNSProvider.all.map(\.addresses) {
                commands.append(setCommand(escaped(service), addresses))
            }
        }
        commands += ["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"]
        return [
            "# Nimb: lets \(user) switch DNS between Nimb's providers and automatic without a password. Remove this file to undo.",
            "\(user) ALL = (root) NOPASSWD: \(commands.joined(separator: ", "))",
        ]
    }

    /// Installs (or renews) the sudoers rule for the services present now. Asks for the administrator password once.
    static func enablePasswordless() throws {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw DNSError.failed("Имя пользователя «\(user)» содержит необычные символы, правило для него не создаю.")
        }
        let services = physicalServices().filter(isRuleSafe)
        guard !services.isEmpty else { throw DNSError.failed("Не нашёл сетевых подключений, для которых можно составить правило.") }
        let script = ruleInstallScript(at: sudoersPath, lines: sudoersRule(for: user, services: services))
        try runPrivileged(script)
        let state = passwordlessState(for: services)
        guard state.enabled, state.missing.isEmpty else { throw DNSError.failed("Правило установлено, но sudo всё равно просит пароль.") }
    }

    /// The script that checks a rule with visudo and installs it as `path`: nothing is installed unless the rule is valid.
    static func ruleInstallScript(at path: String, lines: [String]) -> String {
        let quoted = lines.map(shellQuote).joined(separator: " ")
        return [
            "set -e",
            "grep -Eq '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers[.]d' /etc/sudoers || { echo \(shellQuote("В /etc/sudoers не подключена папка sudoers.d.")) >&2; exit 1; }",
            "mkdir -p /etc/sudoers.d",
            "tmp=$(/usr/bin/mktemp /tmp/nimb-sudoers.XXXXXX)",
            "trap 'rm -f \"$tmp\"' EXIT",
            "printf '%s\\n' \(quoted) > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null || { echo \(shellQuote("Правило не прошло проверку visudo, ничего не установлено.")) >&2; exit 1; }",
            "/usr/bin/install -m 440 -o root -g wheel \"$tmp\" \(path)",
        ].joined(separator: "; ")
    }

    /// Whether sudo lets this user run every one of the commands (each as one line, like `/path/to/tool up`) without a password.
    static func sudoAllows(_ commands: [String]) -> Bool {
        let list = noPasswordList()
        return commands.allSatisfy(list.allows)
    }

    /// Runs a command as root through `sudo -n`: it fails at once, without asking, if a password would be needed.
    @discardableResult
    static func runWithoutPassword(_ arguments: [String]) throws -> String {
        try run("/usr/bin/sudo", ["-n"] + arguments, timeout: nil)
    }

    /// Removes the sudoers rule again. Asks for the administrator password.
    static func disablePasswordless() throws {
        try runPrivileged("/bin/rm -f \(sudoersPath)")
        if passwordlessState(for: physicalServices()).enabled {
            throw DNSError.failed("Правило Nimb удалено, но в системе есть другое правило sudo без пароля.")
        }
    }

    /// The same commands as `applyScript`, each one through `sudo -n`, so nothing is asked.
    private static func applyWithSudo(_ provider: DNSProvider?, to services: [String]) throws {
        let addresses = provider?.addresses ?? ["Empty"]
        var failures: [String] = []
        func sudo(_ args: [String], _ failure: String) {
            do { _ = try run("/usr/bin/sudo", ["-n"] + args, timeout: nil) } catch DNSError.failed(let message) {
                failures.append("\(failure) \(message)")
            } catch {
                failures.append(failure)
            }
        }
        for service in services {
            sudo(["/usr/sbin/networksetup", "-setdnsservers", service] + addresses, "Не удалось изменить DNS: \(service).")
        }
        sudo(["/usr/bin/dscacheutil", "-flushcache"], "Не удалось сбросить кэш DNS (dscacheutil).")
        sudo(["/usr/bin/killall", "-HUP", "mDNSResponder"], "Не удалось перезапустить mDNSResponder.")
        if !failures.isEmpty { throw DNSError.failed(failures.joined(separator: "\n")) }
    }

    /// Runs a shell script as root after the system's password (or Touch ID) prompt; returns what it printed. Calls that come together
    /// after `PrivilegedBatch.shared.expect` are done under one prompt.
    @discardableResult
    static func runPrivileged(_ script: String) throws -> String {
        try PrivilegedBatch.shared.run(script)
    }

    /// The prompt itself, for one script.
    @discardableResult
    static func runPrivilegedNow(_ script: String) throws -> String {
        do {
            return try run("/usr/bin/osascript", ["-e", appleScript(running: script)], timeout: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch DNSError.failed(let message) {
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                throw DNSError.cancelled
            }
            throw DNSError.failed(cleanScriptError(message))
        }
    }

    /// The line of AppleScript that runs `script` in the shell, with the password prompt or (for a test) without it. AppleScript gives
    /// back what the script printed with the line ends changed to carriage returns (`\r`), so a reader of the output must not wait for `\n`.
    static func appleScript(running script: String, privileged: Bool = true) -> String {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\"" + (privileged ? " with administrator privileges" : "")
    }

    /// osascript reports "0:123: execution error: <stderr> (1)"; keep only the stderr text.
    private static func cleanScriptError(_ message: String) -> String {
        var text = message
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: #" \(-?\d+\)\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// How long a command that only reads may take. A system tool that hangs must not keep the window from opening: the first reading
    /// is made while the window is built.
    static let readTimeout: TimeInterval = 3

    /// Runs a command and returns what it printed. `timeout` stops a command that does not answer (nil: wait as long as it takes, for the
    /// ones that wait for a person or change the system).
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval? = readTimeout) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Not waitUntilExit(): it spins the run loop, and this is called while SwiftUI is still building the window,
        // where a re-entrant update makes SwiftUI abort.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = TimedOut()
        if let timeout {
            // A thread of its own: the pool of the dispatch queues may be full of requests that wait (the check of the providers), and a
            // time out that waits for a free thread is no time out.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: timeout)
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                // A command that ignores the polite request is not waited for.
                Thread.sleep(forTimeInterval: 1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        if timedOut.value, let timeout {
            throw DNSError.failed("\(URL(fileURLWithPath: path).lastPathComponent) не ответил за \(Int(timeout)) с.")
        }
        let stdout = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DNSError.failed(message.isEmpty ? "Команда завершилась с кодом \(process.terminationStatus)." : message)
        }
        return stdout
    }

    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
