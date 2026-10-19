import Foundation

struct WarpConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A tunnel written in the format of WireGuard and AmneziaWG (`[Interface]` and `[Peer]` with `Key = Value` lines).
/// Only known keys are taken, every value is checked, and the result is a flat list of `key=value` lines for the helper,
/// which reads it as plain text. Lines that would run commands (`PostUp` and the like) are never carried over.
struct WarpConfig {
    struct Summary: Equatable {
        var endpoint = ""
        var addresses: [String] = []
        var allowedIPs: [String] = []
        var obfuscation: [String] = []
        /// Settings that were left out, with the reason, to show to the person.
        var ignored: [String] = []

        var isFullTunnel: Bool { allowedIPs.contains("0.0.0.0/0") || allowedIPs.contains("::/0") }
    }

    /// The text of `warp.conf` for the helper.
    let file: String
    let summary: Summary

    private static let deviceKeys: [String: String] = [
        "jc": "jc", "jmin": "jmin", "jmax": "jmax", "s1": "s1", "s2": "s2", "s3": "s3", "s4": "s4",
        "h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4", "i1": "i1", "i2": "i2", "i3": "i3", "i4": "i4", "i5": "i5",
        "headerprotectionkey": "header_protection_key", "contentpaddingaddition": "content_padding_addition",
        "rekeyaftertime": "rekey_after_time", "rekeytimeout": "rekey_timeout", "rejectaftertime": "reject_after_time",
        "keepalivetimeout": "keepalive_timeout", "maxhandshakeattempts": "max_handshake_attempts",
        "randomtrailers": "random_trailers", "disablecookies": "disable_cookies",
    ]
    private static let numberOrRange = #"^\d{1,10}(-\d{1,10})?$"#
    private static let cidr = #"^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]{2,39})/[0-9]{1,3}$"#

    static func parse(_ text: String) throws -> WarpConfig {
        var section = ""
        var peers = 0
        var summary = Summary()
        var out: [String] = ["# Nimb WARP tunnel, written by Nimb. Not for editing by hand."]
        var seenPrivate = false, seenPublic = false, seenEndpoint = false

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // A comment after a value; the I1-I5 lines are left alone, their text is free-form.
            if !line.lowercased().hasPrefix("i"), let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                if section == "[peer]" { peers += 1 }
                guard section == "[interface]" || section == "[peer]" else { throw WarpConfigError("Неизвестный раздел \(line).") }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw WarpConfigError("Строка без «=»: \(line.prefix(40)).") }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let key = name.lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            if section == "[interface]" {
                switch key {
                case "privatekey":
                    try requireKey(value, "PrivateKey"); seenPrivate = true
                    out.append("private_key=\(value)")
                case "address":
                    for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        guard part.range(of: cidr, options: .regularExpression) != nil else { throw WarpConfigError("Неверный Address: \(part).") }
                        summary.addresses.append(part)
                        out.append("address=\(part)")
                    }
                case "mtu":
                    guard let mtu = Int(value), (576...1500).contains(mtu) else { throw WarpConfigError("MTU должен быть от 576 до 1500.") }
                    out.append("mtu=\(mtu)")
                case "dns": summary.ignored.append("DNS (системный DNS остаётся прежним, например, сервис Nimb)")
                case "listenport", "table", "saveconfig": summary.ignored.append(name)
                case "preup", "postup", "predown", "postdown": summary.ignored.append("\(name) (команды не выполняются)")
                default:
                    guard let uapi = deviceKeys[key] else { summary.ignored.append(name); continue }
                    try requireValue(value, name)
                    if uapi.hasPrefix("h") || ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"].contains(uapi) {
                        guard value.range(of: numberOrRange, options: .regularExpression) != nil else { throw WarpConfigError("\(name) должен быть числом или диапазоном, а не «\(value.prefix(30))».") }
                    }
                    out.append("\(uapi)=\(value)")
                    summary.obfuscation.append(name)
                }
            } else if section == "[peer]" {
                guard peers == 1 else { throw WarpConfigError("Поддерживается один сервер ([Peer]), а в настройках их несколько.") }
                switch key {
                case "publickey":
                    try requireKey(value, "PublicKey"); seenPublic = true
                    out.append("public_key=\(value)")
                case "presharedkey":
                    try requireKey(value, "PresharedKey")
                    out.append("preshared_key=\(value)")
                case "endpoint":
                    guard value.range(of: #"^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$"#, options: .regularExpression) != nil,
                          let port = Int(value.split(separator: ":").last ?? ""), (1...65535).contains(port) else {
                        throw WarpConfigError("Неверный Endpoint: \(value.prefix(60)).")
                    }
                    seenEndpoint = true
                    summary.endpoint = value
                    out.append("endpoint=\(value)")
                case "allowedips":
                    for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                        guard part.range(of: cidr, options: .regularExpression) != nil else { throw WarpConfigError("Неверный AllowedIPs: \(part).") }
                        summary.allowedIPs.append(part)
                        out.append("allowed_ip=\(part)")
                    }
                case "persistentkeepalive":
                    guard value.range(of: numberOrRange, options: .regularExpression) != nil else { throw WarpConfigError("PersistentKeepalive должен быть числом.") }
                    out.append("persistent_keepalive_interval=\(value)")
                case "protocolversion":
                    guard value.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil else { throw WarpConfigError("ProtocolVersion должен быть числом.") }
                    out.append("protocol_version=\(value)")
                default: summary.ignored.append(name)
                }
            } else {
                throw WarpConfigError("Настройка вне раздела: \(line.prefix(40)).")
            }
        }
        guard seenPrivate else { throw WarpConfigError("Нет PrivateKey в разделе [Interface].") }
        guard seenPublic, seenEndpoint else { throw WarpConfigError("В разделе [Peer] нужны PublicKey и Endpoint.") }
        guard !summary.allowedIPs.isEmpty else { throw WarpConfigError("В разделе [Peer] нет AllowedIPs.") }
        guard !summary.addresses.isEmpty else { throw WarpConfigError("В разделе [Interface] нет Address.") }
        return WarpConfig(file: out.joined(separator: "\n") + "\n", summary: summary)
    }

    private static func requireKey(_ value: String, _ name: String) throws {
        guard let data = Data(base64Encoded: value), data.count == 32 else { throw WarpConfigError("\(name) должен быть ключом WireGuard (44 символа base64).") }
    }

    /// Values go into one line of the helper's input: printable characters only, and not too long.
    private static func requireValue(_ value: String, _ name: String) throws {
        let printable = value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f }
        guard printable, !value.isEmpty, value.count <= 4096 else { throw WarpConfigError("Недопустимое значение \(name).") }
    }
}
