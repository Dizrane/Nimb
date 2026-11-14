import Foundation

/// Budget the encoded JSON string, including escaped control characters, before signing its exact final text.
enum ReportPayload {
    static let textBudget = 60_000
    static let bodyLimit = 100_000

    static func fitted(_ text: String) throws -> String {
        func size(_ value: String) throws -> Int {
            try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]).count
        }
        guard try size(text) > textBudget else { return text }
        let scalars = Array(text.unicodeScalars)
        func cut(_ count: Int) -> String {
            let head = String(String.UnicodeScalarView(scalars.prefix((count + 1) / 2)))
            let tail = String(String.UnicodeScalarView(scalars.suffix(count / 2)))
            return head + "\n…\n" + tail
        }
        var low = 0, high = scalars.count
        while low < high {
            let middle = low + (high - low + 1) / 2
            if try size(cut(middle)) <= textBudget { low = middle } else { high = middle - 1 }
        }
        return cut(low)
    }
}
