import Foundation

/// One request to one address of a site, and what came of it.
struct SiteProbe: Identifiable, Equatable {
    let name: String
    let url: String
    /// The answer of the server, 0 if there was none.
    let code: Int
    let seconds: Double
    /// Why there was no answer, in words.
    let failure: String?

    var id: String { url }
    /// A successful response or redirect; refusals and missing resources are not successful checks.
    var answered: Bool { failure == nil && (200..<400).contains(code) }
    var host: String { URL(string: url)?.host ?? url }

    /// The line shown next to the name.
    var summary: String {
        if let failure { return failure }
        let time = seconds.formatted(.number.precision(.fractionLength(1)))
        if answered { return "ответ \(code) · \(time) с" }
        return "ответ \(code) (\(code >= 500 ? "ошибка сервера" : "ошибка запроса"))"
    }
}
