import Foundation

/// Takes out of a text what a person would not want to send: addresses, e-mails, the name of the Mac user and long keys. A known
/// address of a DNS service of Nimb is replaced with its name, so that the report still says which one it was.
enum ReportRedactor {
    static func clean(_ text: String) -> String {
        var result = text
        // The addresses of the DNS services of Nimb stay, as names.
        for provider in DNSProvider.all {
            for address in provider.addresses { result = result.replacingOccurrences(of: address, with: "‹\(provider.name)›") }
        }
        result = result.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if NSUserName().count >= 4 { result = result.replacingOccurrences(of: NSUserName(), with: "‹user›") }
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
