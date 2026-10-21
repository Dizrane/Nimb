import Foundation
import Testing
@testable import Nimb

/// What may leave the Mac in a report: nothing that names the person.
@Suite struct ReportRedactorTests {
    @Test func hidesAddressesAndEmails() {
        let text = ReportRedactor.clean("не удалось 8.8.8.8 и 192.168.1.15, письмо me@example.com, ещё a.b-c@sub.example.co.uk")
        #expect(!text.contains("8.8.8.8"))
        #expect(!text.contains("192.168"))
        #expect(!text.contains("@example"))
        #expect(!text.contains("@sub"))
        #expect(text.contains("‹ip›"))
        #expect(text.contains("‹e-mail›"))
    }

    @Test func hidesIPv6() {
        #expect(ReportRedactor.clean("a 2a02:6b8::feed:bad:1234 b").contains("‹ipv6›"))
        #expect(!ReportRedactor.clean("a 2a02:6b8::feed:bad:1234 b").contains("2a02"))
    }

    @Test func hidesLongKeys() {
        let key = Data(repeating: 9, count: 32).base64EncodedString()
        #expect(!ReportRedactor.clean("private_key=\(key)").contains(key))
        #expect(ReportRedactor.clean("private_key=\(key)").contains("‹ключ›"))
    }

    @Test func providerAddressesBecomeTheirNames() {
        let provider = DNSProvider.all[0]
        let text = ReportRedactor.clean("DNS: \(provider.addresses.joined(separator: ", "))")
        #expect(text == "DNS: ‹\(provider.name)›", "two addresses of one service read as one name")
    }

    @Test func hidesTheHomeFolder() {
        #expect(ReportRedactor.clean("\(NSHomeDirectory())/Library/Logs/Nimb") == "~/Library/Logs/Nimb")
    }

    @Test func leavesTimesVersionsAndWordsAlone() {
        let line = "2026-10-20 14:03:11 [app] запуск Nimb 0.9.4, macOS 26.0.1 порт 1443"
        #expect(ReportRedactor.clean(line) == line)
    }
}

@MainActor
@Suite struct DiagnosticReportTests {
    @Test func theHeadHasTheNumberAndWhatWasWritten() {
        let head = DiagnosticReport.head(id: "AB12CD", description: "  Не включается туннель  ", contact: "")
        #expect(head.hasPrefix("Отчёт № AB12CD"))
        #expect(head.contains("Не включается туннель"))
        #expect(!head.contains("Как ответить"))
    }

    @Test func theContactIsAddedOnlyWhenGiven() {
        let head = DiagnosticReport.head(id: "AB12CD", description: "x", contact: "@someone")
        #expect(head.contains("Как ответить: @someone"))
    }

    @Test func anEmptyDescriptionIsSaidSo() {
        #expect(DiagnosticReport.head(id: "AB12CD", description: "   ", contact: "").contains("(не описано)"))
    }

    @Test func whatThePersonTypedIsCleanedToo() {
        let head = DiagnosticReport.head(id: "AB12CD", description: "мой ip 93.184.216.34, почта a@b.com", contact: "")
        #expect(!head.contains("93.184"))
        #expect(!head.contains("a@b.com"))
    }

    @Test func idsAreSixLettersWithoutLookalikes() {
        for _ in 0..<200 {
            let id = DiagnosticReport.newID()
            #expect(id.count == 6)
            #expect(id.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) })
        }
    }

    private func report(logLines: Int) -> String {
        let log = (0..<logLines).map { "2026-10-20 10:00:\(String(format: "%02d", $0 % 60)) [app] строка журнала номер \($0)" }
        return (["Отчёт № AB12CD", "", "— Программа —", "Nimb 0.9.4", "", "— Журнал (последние строки) —"] + log).joined(separator: "\n")
    }

    @Test func aShortReportIsLeftAsItIs() {
        let text = report(logLines: 5)
        #expect(DiagnosticReport.fitted(text, limit: 4000) == text)
    }

    @Test func aLongReportLosesTheOldestLinesOfTheDiaryFirst() {
        let text = report(logLines: 200)
        let fitted = DiagnosticReport.fitted(text, limit: 1000)
        #expect(fitted.count <= 1000)
        #expect(fitted.hasPrefix("Отчёт № AB12CD"))
        #expect(fitted.contains("Nimb 0.9.4"))
        #expect(fitted.contains("номер 199"), "the newest lines stay")
        #expect(!fitted.contains("номер 0\n") && !fitted.contains("номер 1\n"), "the oldest go")
    }
}

@Suite struct ReportConfigTests {
    @Test func theAddressOfTheRelayIsSetAndSecure() throws {
        let url = try #require(ReportConfig.endpoint)
        #expect(url.scheme == "https")
        #expect(url.host?.hasSuffix(".workers.dev") == true)
        #expect(ReportConfig.canSend)
    }

    @Test func aMessageToTheDeveloperFitsInOneTelegramMessage() {
        #expect(ReportConfig.messageLimit <= 4096)
        #expect(!ReportConfig.developerHandle.hasPrefix("@"))
    }
}

/// A report must not carry names that someone chose: a router, a phone, a company's VPN.
@Suite struct ReportServiceNamesTests {
    @Test(arguments: ["Wi-Fi", "Ethernet", "Ethernet 2", "Ethernet Adapter (en6)", "Thunderbolt Bridge", "Thunderbolt Ethernet Slot 1",
                      "USB 10/100/1000 LAN", "iPhone USB", "iPad USB 2", "Bluetooth PAN"])
    func theNamesOfMacOSAreGeneric(name: String) {
        #expect(ReportRedactor.isGenericService(name))
    }

    @Test(arguments: ["Daniil’s iPhone", "Home router 5G", "Acme Corp", "Wi-Fi (Ivan)", "Ethernet Adapter (en6) Ivan"])
    func aNameSomeoneChoseIsNotGeneric(name: String) {
        #expect(!ReportRedactor.isGenericService(name))
    }

    @Test func aChosenNameIsReplacedAndAGenericOneStays() {
        let services = ["Wi-Fi", "Daniil’s iPhone", "Thunderbolt Bridge", "Home router 5G"]
        let text = ReportRedactor.clean("DNS на «Wi-Fi»: авто\nDNS на «Daniil’s iPhone»: авто\nнет на: Home router 5G, Thunderbolt Bridge", services: services)
        #expect(text.contains("«Wi-Fi»"))
        #expect(text.contains("Thunderbolt Bridge"))
        #expect(!text.contains("Daniil"))
        #expect(!text.contains("router"))
        #expect(text.contains("‹подключение 2›"))
        #expect(text.contains("‹подключение 4›"))
    }

    @Test func aShortNameInsideAWordIsLeftAlone() {
        #expect(ReportRedactor.clean("LANDING и Landlord", services: ["LAN x"]) == "LANDING и Landlord")
        #expect(ReportRedactor.clean("слово Lan и ещё слово", services: ["Lan"]) == "слово ‹подключение 1› и ещё слово")
        #expect(ReportRedactor.clean("Landing", services: ["Lan"]) == "Landing")
    }

    @Test func theNameOfAVPNIsHidden() {
        let text = ReportRedactor.clean("Включён VPN «Acme Corp»: он может использовать свой DNS.")
        #expect(text == "Включён VPN «‹название›»: он может использовать свой DNS.")
    }

    @Test func noConnectionsMeansNothingIsReplaced() {
        #expect(ReportRedactor.clean("DNS на «Home router 5G»: авто") == "DNS на «Home router 5G»: авто")
    }
}
