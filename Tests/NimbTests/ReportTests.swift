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

/// «Ждали / увидели»: each service says what must be there and what is there; a disagreement is spelled out.
@Suite struct ServiceCheckTests {
    private let provider = DNSProvider.all[0]
    private let router = ["192.168.0.1"]

    @Test func dnsOnAndEverywhereAndAskedIsAgreed() {
        let check = ReportChecks.dns(active: provider, serviceServers: [provider.addresses, provider.addresses], resolver: provider.addresses)
        #expect(check.agrees)
        #expect(check.lines.last == "  итог: совпало")
        #expect(check.seen.contains("2 из 2"))
    }

    @Test func dnsOnButOneConnectionIsAutomaticDisagrees() {
        let check = ReportChecks.dns(active: provider, serviceServers: [provider.addresses, []], resolver: provider.addresses)
        #expect(!check.agrees)
        #expect(check.seen.contains("1 из 2"))
        #expect(check.lines.last == "  итог: РАСХОДИТСЯ")
    }

    @Test func dnsOnButTheSystemAsksTheRouterDisagrees() {
        let check = ReportChecks.dns(active: provider, serviceServers: [provider.addresses], resolver: router)
        #expect(!check.agrees, "set everywhere, but something else decides: a VPN, a profile, a browser of its own")
        #expect(check.seen.contains("192.168.0.1"))
    }

    @Test func dnsOffIsAgreedWhenNothingOfNimbIsLeft() {
        #expect(ReportChecks.dns(active: nil, serviceServers: [[], router], resolver: router).agrees)
        let left = ReportChecks.dns(active: nil, serviceServers: [DNSProvider.all[1].addresses, []], resolver: router)
        #expect(!left.agrees)
        #expect(left.seen.contains("1 из 2"))
    }

    @Test func aProxyThatWorksIsAgreed() {
        var stats = TelegramProxyStats()
        stats.totalConnections = 18; stats.webSocket = 18
        let check = ReportChecks.telegram(running: true, port: 1443, listening: true, stats: stats)
        #expect(check.agrees)
        #expect(check.seen.contains("через WebSocket 18"))
    }

    @Test func aProxyThatHasNotMetTelegramYetIsAgreedAndSaysSo() {
        let check = ReportChecks.telegram(running: true, port: 1443, listening: true, stats: TelegramProxyStats())
        #expect(check.agrees)
        #expect(check.seen.contains("ещё не подключался"))
    }

    @Test func aProxyThatDoesNotListenDisagrees() {
        #expect(!ReportChecks.telegram(running: true, port: 1443, listening: false, stats: TelegramProxyStats()).agrees)
    }

    @Test func aProxyWithManyErrorsOrAnotherKeyDisagrees() {
        var many = TelegramProxyStats()
        many.totalConnections = 10; many.failures = 3
        #expect(!ReportChecks.telegram(running: true, port: 1443, listening: true, stats: many).agrees)
        var key = TelegramProxyStats()
        key.totalConnections = 10; key.wrongSecret = 1
        #expect(!ReportChecks.telegram(running: true, port: 1443, listening: true, stats: key).agrees)
        var fine = TelegramProxyStats()
        fine.totalConnections = 10; fine.failures = 2
        #expect(ReportChecks.telegram(running: true, port: 1443, listening: true, stats: fine).agrees)
    }

    @Test func aProxyThatIsOffButStillListensDisagrees() {
        #expect(ReportChecks.telegram(running: false, port: 1443, listening: false, stats: TelegramProxyStats()).agrees)
        #expect(!ReportChecks.telegram(running: false, port: 1443, listening: true, stats: TelegramProxyStats()).agrees)
    }

    @Test func aTunnelThatWorksIsAgreed() {
        #expect(ReportChecks.tunnel(on: true, routes: 3, interface: "utun5", warp: "on", dropped: nil).agrees)
    }

    @Test func aTunnelThatIsOnButNotCarryingTrafficDisagrees() {
        #expect(!ReportChecks.tunnel(on: true, routes: 3, interface: "utun5", warp: "off", dropped: nil).agrees, "Cloudflare does not see WARP")
        #expect(!ReportChecks.tunnel(on: true, routes: 3, interface: "en0", warp: "on", dropped: nil).agrees, "the traffic does not go into the tunnel")
        #expect(!ReportChecks.tunnel(on: true, routes: 0, interface: "utun5", warp: "on", dropped: nil).agrees)
        #expect(!ReportChecks.tunnel(on: true, routes: 3, interface: "utun5", warp: nil, dropped: nil).agrees, "Cloudflare did not answer")
    }

    @Test func aTunnelThatIsOffIsAgreedWhenTheTrafficIsDirect() {
        #expect(ReportChecks.tunnel(on: false, routes: 0, interface: "en0", warp: "off", dropped: nil).agrees)
        #expect(!ReportChecks.tunnel(on: false, routes: 0, interface: "utun3", warp: "off", dropped: nil).agrees, "another VPN carries the traffic")
    }

    @Test func whenTheTunnelEndedByItselfTheReportSaysSo() {
        let check = ReportChecks.tunnel(on: false, routes: 0, interface: "en0", warp: "off", dropped: "daemon-exited в 10-21 21:40")
        #expect(check.seen.contains("туннель остановился сам (daemon-exited в 10-21 21:40)"))
    }

    @Test func readsTheProxiesThatAreOn() {
        let output = """
        <dictionary> {
          HTTPEnable : 1
          HTTPPort : 8080
          HTTPProxy : proxy.example.test
          HTTPSEnable : 0
          SOCKSEnable : 1
          ProxyAutoConfigEnable : 0
        }
        """
        #expect(ReportChecks.proxies(from: output) == ["HTTP", "SOCKS"])
        #expect(ReportChecks.proxies(from: "<dictionary> {\n  HTTPEnable : 0\n}").isEmpty)
        #expect(!ReportChecks.proxies(from: output).joined().contains("example"), "only the kinds, never the addresses")
    }

    @Test func findsTheDomainsThatHaveALineInTheHostsFile() {
        let hosts = "127.0.0.1 localhost\n# 1.2.3.4 chatgpt.com\n0.0.0.0 api.anthropic.com\n"
        #expect(ReportChecks.hostsMentions(in: hosts, domains: ["chatgpt.com", "api.anthropic.com", "t.me"]) == ["api.anthropic.com"])
    }

    @Test func theBlackBoxLineIsReadableByAProgram() {
        let facts = BlackBoxLine.Facts(dns: "GeoHide (EU)", dnsAgrees: true, telegram: "вкл:1443 соединений=62 ошибок=0", telegramAgrees: true,
                                       tunnel: "вкл:utun4", tunnelAgrees: false, routes: 5, interface: "utun4")
        let line = BlackBoxLine.line(now: Date(timeIntervalSince1970: 1_792_600_000), uptime: 4 * 3600 + 12 * 60, facts: facts, memoryMegabytes: 84)
        #expect(line.contains("работает=4ч12м"))
        #expect(line.contains("dns=GeoHide (EU) совпало=да"))
        #expect(line.contains("туннель=вкл:utun4 совпало=НЕТ маршрутов=5"), "a disagreement stands out in capitals")
        #expect(line.contains("память=84МБ"))
    }

    @Test func theBlackBoxKeepsADayOfLines() {
        let many = (1...400).map { "line \($0)" }
        let kept = BlackBoxLine.trimmed(many)
        #expect(kept.count == BlackBoxLine.keepLines)
        #expect(kept.last == "line 400" && kept.first == "line 113")
    }

    @Test func keepsTheAddressesOfThePoolsThatHelpAndReplacesTheRest() {
        let text = "отказ: Gemini · 5.175.161.40: перенаправление; DNS 192.168.1.1; чужой 8.8.4.4; свой пул 10.0.0.7"
        let clean = ReportRedactor.clean(text, keep: ["5.175.161.40", "10.0.0.7"])
        #expect(clean.contains("5.175.161.40"), "an address of a pool that refused stays: it shows which address is bad")
        #expect(!clean.contains("192.168.1.1") && !clean.contains("8.8.4.4"))
        #expect(!clean.contains("10.0.0.7"), "a private address never stays, even when it is asked to")
        #expect(ReportRedactor.isPrivateAddress("172.20.1.1") && !ReportRedactor.isPrivateAddress("172.32.1.1"))
    }

    @Test func theTunnelCheckTellsAboutRestartsButStillAgrees() {
        let now = Date()
        let check = ReportChecks.tunnel(on: true, routes: 3, interface: "utun5", warp: "on", dropped: nil, restarts: [now.addingTimeInterval(-600), now])
        #expect(check.agrees)
        #expect(check.seen.contains("запускалась снова за сутки: 2"))
        #expect(!ReportChecks.tunnel(on: true, routes: 3, interface: "utun5", warp: "on", dropped: nil).seen.contains("запускалась снова"))
    }

    @Test func theTailOfTheDaemonLogIsTheLastLinesWithoutEmptyOnes() {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n\n") + "\n"
        let tail = ReportChecks.logTail(text, limit: 3)
        #expect(tail == ["line 38", "line 39", "line 40"])
        #expect(ReportChecks.logTail("\n \n") == ["пусто"])
    }

    @Test func theDaemonLogLosesAddressesAndKeysInTheReport() {
        let line = "VERBOSE: (utun4) 2026/10/22 03:49:59 peer(bmXO…fgyo) - Failed to send handshake initiation: write udp4 0.0.0.0:55656->162.159.195.2:500: network is unreachable"
        let clean = ReportRedactor.clean(ReportChecks.logTail(line).joined(separator: "\n"))
        #expect(!clean.contains("162.159.195.2"))
        #expect(clean.contains("network is unreachable"))
    }

    @Test func countsTheConnectedVPNs() {
        let list = """
        * (Connected)      AAA VPN (x) "One"  [VPN:x]
        * (Disconnected)   BBB VPN (y) "Two"  [VPN:y]
        * (Connected)      CCC VPN (z) "Three"  [VPN:z]
        """
        #expect(ReportChecks.connectedVPNs(from: list) == 2)
    }
}

/// The events of the last day, out of the lines of the diary.
@Suite struct ReportChronologyTests {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ minutesAgo: Double, _ tag: String, _ message: String) -> String {
        "\(Self.stamp.string(from: now.addingTimeInterval(-minutesAgo * 60))) [\(tag)] \(message)"
    }

    @Test func keepsTheStatesAndErrorsOfTheServices() {
        let events = ReportChronology.events(from: [
            line(50, "dns", "DNS: GeoHide (EU)"), line(40, "telegram", "прокси включён, порт 1443"), line(30, "tunnel", "ошибка: нет рукопожатия"),
        ], now: now)
        #expect(events.count == 3)
        #expect(events[0].hasSuffix("[dns] DNS: GeoHide (EU)"))
        #expect(events[2].hasSuffix("[tunnel] ошибка: нет рукопожатия"))
    }

    @Test func leavesOutTheChecksOfUpdatesThatFoundNothing() {
        let events = ReportChronology.events(from: [
            line(60, "update", "проверяю обновления"), line(60, "update", "версия 0.9.9 актуальна"), line(20, "dns", "DNS: выключен"),
        ], now: now)
        #expect(events.count == 1)
        #expect(events[0].hasSuffix("[dns] DNS: выключен"))
    }

    @Test func leavesOutTheMomentsInWork() {
        let events = ReportChronology.events(from: [
            line(30, "tunnel", "состояние: working(\"Включаю…\")"), line(29, "tunnel", "состояние: on(interface: \"utun4\")"),
        ], now: now)
        #expect(events.count == 1)
        #expect(events[0].contains("on(interface"))
    }

    @Test func keepsAFailedCheckAndANewVersion() {
        let events = ReportChronology.events(from: [
            line(60, "update", "проверка обновлений не удалась: нет сети"), line(10, "update", "есть новая версия 0.9.10"),
        ], now: now)
        #expect(events.count == 2)
    }

    @Test func tellsALineThatComesAgainAndAgainOnceWithACount() {
        let events = ReportChronology.events(from: [
            line(30, "update", "проверка обновлений не удалась: нет сети"), line(20, "update", "проверка обновлений не удалась: нет сети"),
            line(10, "update", "проверка обновлений не удалась: нет сети"), line(5, "dns", "DNS: выключен"),
        ], now: now)
        #expect(events.count == 2)
        #expect(events[0].hasSuffix("не удалась: нет сети (×3)"))
    }

    @Test func leavesOutWhatIsOlderThanADay() {
        let events = ReportChronology.events(from: [line(25 * 60, "dns", "DNS: GeoHide (EU)"), line(23 * 60, "dns", "DNS: выключен")], now: now)
        #expect(events.count == 1)
        #expect(events[0].hasSuffix("DNS: выключен"))
    }

    @Test func keepsTheLastOnesWhenThereAreTooMany() {
        let lines = (0..<100).map { line(Double(200 - $0), "dns", "DNS: \($0)") }
        let events = ReportChronology.events(from: lines, now: now, limit: 10)
        #expect(events.count == 10)
        #expect(events.last?.hasSuffix("DNS: 99") == true)
        #expect(events.first?.hasSuffix("DNS: 90") == true)
    }

    @Test func skipsLinesThatAreNotOfTheDiary() {
        let events = ReportChronology.events(from: ["", "nonsense", "2026-13-45 99:99:99 [dns] x", line(5, "dns", "DNS: выключен")], now: now)
        #expect(events.count == 1)
    }

    @Test func saysWhenThereWasNothing() {
        #expect(ReportChronology.events(from: [], now: now) == ["за последние сутки событий нет"])
    }
}


@Suite struct AutoReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstReportGoesAndTheSameCauseWaitsSixHours() {
        #expect(AutoReportPolicy.allows(key: "crash", now: now, history: []))
        let sent = [AutoReportPolicy.Sent(key: "crash", at: now.addingTimeInterval(-2 * 3600))]
        #expect(!AutoReportPolicy.allows(key: "crash", now: now, history: sent), "the same cause is not told again within six hours")
        #expect(AutoReportPolicy.allows(key: "crash", now: now.addingTimeInterval(5 * 3600), history: sent))
    }

    @Test func notMoreThanOneAnHourAndFiveADay() {
        let hourAgo = [AutoReportPolicy.Sent(key: "a", at: now.addingTimeInterval(-30 * 60))]
        #expect(!AutoReportPolicy.allows(key: "b", now: now, history: hourAgo), "a second cause within the hour waits")
        let five = (1...5).map { AutoReportPolicy.Sent(key: "k\($0)", at: now.addingTimeInterval(-Double($0) * 3 * 3600)) }
        #expect(!AutoReportPolicy.allows(key: "new", now: now, history: five), "five in a day is the limit")
        #expect(AutoReportPolicy.pruned(five + [AutoReportPolicy.Sent(key: "old", at: now.addingTimeInterval(-30 * 3600))], now: now).count == 5)
    }

    @Test func aDisagreementMustLastTwoLooksAndIsToldOnce() {
        var tracker = MismatchTracker()
        let first = tracker.observe("dns", agrees: false)
        let second = tracker.observe("dns", agrees: false)
        let third = tracker.observe("dns", agrees: false)
        #expect(!first, "one look is a moment of switching")
        #expect(second, "the second in a row is a fault")
        #expect(!third, "and it is told once")
        _ = tracker.observe("dns", agrees: true)
        let again = tracker.observe("dns", agrees: false)
        #expect(!again, "the count begins again after an agreement")
        let other = tracker.observe("telegram", agrees: false)
        #expect(!other, "each service has its own count")
    }

    @Test func theDigestGoesOnceADayAndCountsTheDay() {
        let last = now.addingTimeInterval(-23 * 3600)
        #expect(!DailyDigest.isDue(now: now, last: last))
        #expect(DailyDigest.isDue(now: now.addingTimeInterval(2 * 3600), last: last))
        let lines = [
            "2026-10-23 10:00:00 | работает=1ч00м | dns=Comss совпало=да | telegram=вкл:1080 соединений=4 ошибок=0 совпало=да | туннель=вкл:utun4 совпало=да маршрутов=2 | трафик_через=utun4 | память=120МБ",
            "2026-10-23 10:05:00 | работает=1ч05м | dns=Comss совпало=НЕТ | telegram=выкл совпало=да | туннель=вкл:utun4 совпало=НЕТ маршрутов=0 | трафик_через=en0 | память=180МБ",
            "2026-10-23 10:10:00 | работает=1ч10м | dns=выкл совпало=да | telegram=выкл совпало=да | туннель=выкл совпало=да маршрутов=0 | трафик_через=en0 | память=150МБ",
        ]
        let summary = DailyDigest.summary(lines: lines, sentKeys: ["tunnel-restarted"])
        #expect(summary.contains("Записей чёрного ящика: 3 из 288"))
        #expect(summary.contains("Период записей: с 2026-10-23 10:00:00 по 2026-10-23 10:10:00; работы по записям около 15 мин"))
        #expect(summary.contains("dns: не совпало в 1 записях"))
        #expect(summary.contains("telegram: не совпало в 0 записях"))
        #expect(summary.contains("туннель: не совпало в 1 записях"))
        #expect(summary.contains("до 180 МБ, в последней записи 150 МБ"))
        #expect(summary.contains("Отчётов по сбоям за сутки: 1 (tunnel-restarted)"))
        #expect(DailyDigest.summary(lines: [], sentKeys: []).contains("Записей чёрного ящика: 0"))
    }

    @Test func theDnsOfNimbAgreesByItsSettingsAndNotByWhomTheSystemAsks() throws {
        let provider = try #require(DNSProvider.all.first)
        #expect(AutoReportRules.dnsAgrees(active: provider, serviceServers: [provider.addresses, provider.addresses]))
        #expect(!AutoReportRules.dnsAgrees(active: provider, serviceServers: [provider.addresses, []]), "one connection without it")
        #expect(AutoReportRules.dnsAgrees(active: nil, serviceServers: [[], []]))
        #expect(!AutoReportRules.dnsAgrees(active: nil, serviceServers: [provider.addresses]), "left behind after switching off")
    }

    @Test func theRulesOfAgreement() {
        #expect(AutoReportRules.tunnelAgrees(on: true, routes: 5, viaTunnel: true))
        #expect(!AutoReportRules.tunnelAgrees(on: true, routes: 0, viaTunnel: false))
        #expect(AutoReportRules.tunnelAgrees(on: false, routes: 0, viaTunnel: false))
        #expect(!AutoReportRules.tunnelAgrees(on: false, routes: 3, viaTunnel: true), "routes left behind")
        #expect(AutoReportRules.tunnelAgrees(on: false, routes: 0, viaTunnel: true), "another VPN carries the traffic: not a fault of ours")
        let stats = TelegramProxyStats()
        #expect(AutoReportRules.telegramAgrees(running: false, listening: false, stats: stats))
        #expect(!AutoReportRules.telegramAgrees(running: false, listening: true, stats: stats), "the port is held while it is off")
    }

    @Test func causesHaveKeysAndWords() {
        #expect(AutoTrigger.mismatch(.telegram).key == "mismatch-telegram")
        #expect(AutoTrigger.error(.tunnel).key == "error-tunnel")
        #expect(AutoTrigger.error(.tunnel).title.contains("YouTube и Discord"))
        for trigger in [AutoTrigger.previousEndedBadly, .tunnelRestarted, .tunnelDropped, .mismatch(.dns), .error(.dns), .updateCheck, .dailyDigest] {
            #expect(trigger.key.range(of: "^[A-Za-z0-9:-]{1,40}$", options: .regularExpression) != nil, "the relay takes plain letters in a key")
        }
        #expect(AutoTrigger.previousEndedBadly.key == "crash")
        #expect(AutoTrigger.tunnelDropped.title.contains("не запустился снова"))
        #expect(AutoReporter.newInstallID().count == 8)
    }
}
