import Foundation
import Testing
@testable import Nimb

@Suite struct ReportPayloadTests {
    @Test(arguments: ["я", "🙂", "\u{0001}", "\"\\\n", "<>&/"])
    func largeReportsFitTheWireBudget(unit: String) throws {
        let text = "НАЧАЛО" + String(repeating: unit, count: 100_000) + "КОНЕЦ"
        let cut = try ReportPayload.fitted(text)
        let encoded = try JSONSerialization.data(withJSONObject: cut, options: [.fragmentsAllowed])
        #expect(encoded.count <= ReportPayload.textBudget)
        #expect(cut.hasPrefix("НАЧАЛО") && cut.hasSuffix("КОНЕЦ"))
        #expect(cut.contains("\n…\n"))
        #expect(try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) as? String == cut)
    }

    @Test func shortReportsStayExact() throws {
        #expect(try ReportPayload.fitted("Привет 🙂\nстрока") == "Привет 🙂\nстрока")
    }
}
