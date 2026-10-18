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

    // MARK: Writing (asks for the administrator password)

    /// Sets `provider` on all given services, or resets them to automatic DNS when it is nil.
    static func apply(_ provider: DNSProvider?, to services: [String]) throws {
        let addresses = provider?.addresses.joined(separator: " ") ?? "Empty"
        var commands = services.map {
            "/usr/sbin/networksetup -setdnsservers \(shellQuote($0)) \(addresses)"
        }
        commands.append("/usr/bin/dscacheutil -flushcache")
        commands.append("/usr/bin/killall -HUP mDNSResponder")
        try runPrivileged(commands.joined(separator: "; "))
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
            throw DNSError.failed(message)
        }
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
