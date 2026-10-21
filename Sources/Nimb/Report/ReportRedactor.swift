import Foundation

/// Takes out of a text what a person would not want to send: addresses, e-mails, the name of the Mac user and long keys. A known
/// address of a DNS service of Nimb is replaced with its name, so that the report still says which one it was.
enum ReportRedactor {
    /// The names macOS gives to network connections itself («Wi-Fi», «Thunderbolt Bridge», «Ethernet Adapter (en6)»). They tell nothing about
    /// the person; any other name was chosen by someone (a router, a phone, a company) and does not go into a report.
    static func isGenericService(_ name: String) -> Bool {
        let patterns = [
            #"^Wi-Fi$"#, #"^Ethernet( \d+)?$"#, #"^Ethernet Adapter \(en\d+\)$"#, #"^Thunderbolt Bridge( \d+)?$"#,
            #"^Thunderbolt Ethernet( Slot \d+(, Bridge \d+)?)?$"#, #"^USB( \d+(/\d+)+)? LAN( \d+)?$"#,
            #"^(iPhone|iPad) USB( \d+)?$"#, #"^Bluetooth PAN( \d+)?$"#,
        ]
        return patterns.contains { name.range(of: $0, options: .regularExpression) != nil }
    }

    /// `services` are the names of the network connections of this Mac: those that are not generic are replaced with a number.
    static func clean(_ text: String, services: [String] = []) -> String {
        var result = text
        // The addresses of the DNS services of Nimb stay, as names.
        for provider in DNSProvider.all {
            for address in provider.addresses { result = result.replacingOccurrences(of: address, with: "‹\(provider.name)›") }
        }
        result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if NSUserName().count >= 4 { result = result.replacingOccurrences(of: NSUserName(), with: "‹user›") }
        for (number, service) in services.enumerated() where service.count >= 3 && !isGenericService(service) {
            let name = NSRegularExpression.escapedPattern(for: service)
            result = replace(#"(?<![\p{L}\p{N}])"# + name + #"(?![\p{L}\p{N}])"#, in: result, with: "‹подключение \(number + 1)›")
        }
        // A VPN is named by whoever set it up: often a company.
        result = replace(#"(VPN «)[^»]*(»)"#, in: result, with: "$1‹название›$2")
        result = replace(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: result, with: "‹e-mail›")
        result = replace(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: result, with: "‹ip›")
        result = replace(#"\b[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){3,7}\b"#, in: result, with: "‹ipv6›")
        result = replace(#"[A-Za-z0-9+/=_\-]{32,}"#, in: result, with: "‹ключ›")
        // Two addresses of one service read as one name.
        result = replace(#"(‹[^›]+›)(?:, \1)+"#, in: result, with: "$1")
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
