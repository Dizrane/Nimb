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
    /// The server answered with something other than an error of its own: the site is reachable.
    var answered: Bool { failure == nil && (200..<500).contains(code) }
    var host: String { URL(string: url)?.host ?? url }

    /// The line shown next to the name.
    var summary: String {
        if let failure { return failure }
        let time = seconds.formatted(.number.precision(.fractionLength(1)))
        return answered ? "ответ \(code) · \(time) с" : "ответ \(code) (ошибка сервера)"
    }
}
