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
        return warnings
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
        if isPasswordless {
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
    static func applyScript(_ provider: DNSProvider?, to services: [String]) -> String {
        let addresses = provider?.addresses.joined(separator: " ") ?? "Empty"
        var script = ["failed=0"]
        for service in services {
            let quoted = shellQuote(service)
            script.append("/usr/sbin/networksetup -setdnsservers \(quoted) \(addresses) || { echo \(shellQuote("Не удалось изменить DNS:")) \(quoted) >&2; failed=1; }")
        }
        script.append("/usr/bin/dscacheutil -flushcache || { echo \(shellQuote("Не удалось сбросить кэш DNS (dscacheutil).")) >&2; failed=1; }")
        script.append("/usr/bin/killall -HUP mDNSResponder || { echo \(shellQuote("Не удалось перезапустить mDNSResponder.")) >&2; failed=1; }")
        script.append("exit $failed")
        return script.joined(separator: "; ")
    }

    // MARK: Without a password (opt-in)

    static let sudoersPath = "/etc/sudoers.d/nimb"

    /// True if sudo lets this user change DNS without a password. Checked with `-n`, so it never prompts.
    static var isPasswordless: Bool {
        (try? run("/usr/bin/sudo", ["-n", "-l", "/usr/sbin/networksetup", "-setdnsservers", "Nimb", "Empty"])) != nil
    }

    /// The sudoers rule: only these three commands, for this user. Anything else still asks for the password.
    static func sudoersRule(for user: String) -> [String] {
        [
            "# Nimb: lets \(user) change DNS servers without a password. Remove this file to undo.",
            "\(user) ALL = (root) NOPASSWD: /usr/sbin/networksetup -setdnsservers *, /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder",
        ]
    }

    /// Installs the sudoers rule. Asks for the administrator password once.
    static func enablePasswordless() throws {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw DNSError.failed("Имя пользователя «\(user)» содержит необычные символы, правило для него не создаю.")
        }
        let lines = sudoersRule(for: user).map(shellQuote).joined(separator: " ")
        let script = [
            "set -e",
            "grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers || { echo \(shellQuote("В /etc/sudoers не подключена папка sudoers.d.")) >&2; exit 1; }",
            "mkdir -p /etc/sudoers.d",
            "tmp=$(/usr/bin/mktemp /tmp/nimb-sudoers.XXXXXX)",
            "trap 'rm -f \"$tmp\"' EXIT",
            "printf '%s\\n' \(lines) > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null || { echo \(shellQuote("Правило не прошло проверку visudo, ничего не установлено.")) >&2; exit 1; }",
            "/usr/bin/install -m 440 -o root -g wheel \"$tmp\" \(sudoersPath)",
        ].joined(separator: "; ")
        try runPrivileged(script)
        guard isPasswordless else { throw DNSError.failed("Правило установлено, но sudo всё равно просит пароль.") }
    }

    /// Removes the sudoers rule again. Asks for the administrator password.
    static func disablePasswordless() throws {
        try runPrivileged("/bin/rm -f \(sudoersPath)")
        if isPasswordless {
            throw DNSError.failed("Правило Nimb удалено, но в системе есть другое правило sudo без пароля.")
        }
    }

    /// The same commands as `applyScript`, each one through `sudo -n`, so nothing is asked.
    private static func applyWithSudo(_ provider: DNSProvider?, to services: [String]) throws {
        let addresses = provider?.addresses ?? ["Empty"]
        var failures: [String] = []
        func sudo(_ args: [String], _ failure: String) {
            do { _ = try run("/usr/bin/sudo", ["-n"] + args) } catch DNSError.failed(let message) {
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

    private static func runPrivileged(_ script: String) throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        do {
            _ = try run("/usr/bin/osascript", ["-e", appleScript])
        } catch DNSError.failed(let message) {
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                throw DNSError.cancelled
            }
            throw DNSError.failed(cleanScriptError(message))
        }
    }

    /// osascript reports "0:123: execution error: <stderr> (1)"; keep only the stderr text.
    private static func cleanScriptError(_ message: String) -> String {
        var text = message
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: #" \(-?\d+\)\s*$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DNSError.failed(message.isEmpty ? "Команда завершилась с кодом \(process.terminationStatus)." : message)
        }
        return stdout
    }
}
