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

    @Test func aStackPathIsNotAKey() {
        let line = "\tgithub.com/some-long-organisation/some-long-repository/pkg/device/send.go:112 +0x85"
        #expect(ReportRedactor.clean(line) == line)
    }

    @Test func aProviderAddressThatDidNotAnswerStaysAsAnAddress() {
        let provider = DNSProvider.all[0]
        let dead = provider.addresses[0]
        let text = ReportRedactor.clean("без ответа: \(dead); DNS: \(provider.addresses[1])", keep: [dead])
        #expect(text.contains(dead) && !text.contains(provider.addresses[1]), "the bad address is told, the other one is the name")
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

    @Test func aProxyWithManyErrorsIsStillAgreedButAnotherKeyIsNot() {
        var many = TelegramProxyStats()
        many.totalConnections = 10; many.failures = 8
        #expect(ReportChecks.telegram(running: true, port: 1443, listening: true, stats: many).agrees, "the errors are the network's, the numbers stay in «увидели»")
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

    @Test func aCauseIsWrittenDownOnceWithACount() {
        var causes = DayCauses.recorded([], key: "crash", title: "прошлый запуск закончился неожиданно", at: now)
        causes = DayCauses.recorded(causes, key: "update-check", title: "проверка обновлений не удаётся", at: now.addingTimeInterval(60))
        causes = DayCauses.recorded(causes, key: "crash", title: "прошлый запуск закончился неожиданно", at: now.addingTimeInterval(3600))
        #expect(causes.map(\.key) == ["crash", "update-check"], "the same cause is one line")
        #expect(causes.first?.count == 2)
        #expect(causes.first?.first == now, "the time is of the first one")
        let lines = DayCauses.lines(causes)
        #expect(lines[0].hasSuffix("прошлый запуск закончился неожиданно (раз: 2)"))
        #expect(lines[1].hasSuffix("проверка обновлений не удаётся"), "no count for a cause that came once")
    }

    @Test func theSnapshotOfTheFirstFaultHasItsWordsInTheReport() throws {
        let snapshot = FaultSnapshot(title: "туннель молчит", at: now, text: "— Программа —\nNimb 0.9.23")
        #expect(snapshot.section.hasPrefix("— Снимок первого сбоя ("))
        #expect(snapshot.section.contains("туннель молчит"))
        #expect(snapshot.section.hasSuffix("Nimb 0.9.23"))
        #expect(try JSONDecoder().decode(FaultSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
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
        let summary = DailyDigest.summary(lines: lines, causes: DayCauses.recorded([], key: "tunnel-restarted", title: "программа туннеля остановилась сама", at: now))
        #expect(summary.contains("Записей чёрного ящика: 3 из 288"))
        #expect(summary.contains("Период записей: с 2026-10-23 10:00:00 по 2026-10-23 10:10:00; работы по записям около 15 мин"))
        #expect(summary.contains("dns: не совпало в 1 записях"))
        #expect(summary.contains("telegram: не совпало в 0 записях"))
        #expect(summary.contains("туннель: не совпало в 1 записях"))
        #expect(summary.contains("до 180 МБ, в последней записи 150 МБ"))
        #expect(summary.contains("Сбои за это время:\n  "))
        #expect(summary.contains("программа туннеля остановилась сама"))
        #expect(DailyDigest.summary(lines: [], causes: []).contains("Записей чёрного ящика: 0"))
        #expect(DailyDigest.summary(lines: [], causes: []).contains("Сбоев за это время не было"))
    }

    @Test func theDnsOfNimbAgreesByItsSettingsAndNotByWhomTheSystemAsks() throws {
        let provider = try #require(DNSProvider.all.first)
        #expect(AutoReportRules.dnsAgrees(active: provider, serviceServers: [provider.addresses, provider.addresses]))
        #expect(!AutoReportRules.dnsAgrees(active: provider, serviceServers: [provider.addresses, []]), "one connection without it")
        #expect(AutoReportRules.dnsAgrees(active: nil, serviceServers: [[], []]))
        #expect(!AutoReportRules.dnsAgrees(active: nil, serviceServers: [provider.addresses]), "left behind after switching off")
    }

    @Test func theLastAnswerOfTheServerIsReadFromTheLogOfTheDaemon() throws {
        let log = """
        DEBUG: (utun4) 2026/10/23 21:20:13 peer(bmXO…fgyo) - Received handshake response
        DEBUG: (utun4) 2026/10/23 21:22:14 peer(bmXO…fgyo) - Sending handshake initiation
        DEBUG: (utun4) 2026/10/23 21:22:14 peer(bmXO…fgyo) - Received handshake response
        DEBUG: (utun4) 2026/10/23 21:22:14 peer(bmXO…fgyo) - Sending keepalive packet
        ERROR: (utun4) 2026/10/23 21:30:00 peer(bmXO…fgyo) - Failed to send data packets: sendmsg: can't assign requested address
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let answered = try #require(formatter.date(from: "2026/10/23 21:22:14"))
        #expect(TunnelHandshake.age(inLog: log, now: answered.addingTimeInterval(95)) == 95, "the last answer counts, not the first")
        #expect(TunnelHandshake.age(inLog: "DEBUG: nothing here\nNIMB: 2026/10/23 21:00:00 up", now: answered) == nil)
        #expect(TunnelHandshake.age(inLog: "", now: answered) == nil)
    }

    @Test func aReportThatCouldNotGoWaitsADayAtMostAndOnlyThreeAreKept() {
        func item(_ id: String, _ age: TimeInterval) -> PendingReports.Item {
            PendingReports.Item(id: id, trigger: "tunnel-silent", install: "ABCD2345", text: "text", at: now.addingTimeInterval(-age))
        }
        let kept = PendingReports.fresh([item("old", 25 * 3600), item("a", 3 * 3600), item("b", 2 * 3600), item("c", 3600), item("d", 60)], now: now)
        #expect(kept.map(\.id) == ["b", "c", "d"])
        #expect(PendingReports.fresh([], now: now).isEmpty)
        #expect(PendingReports.decode(nil).isEmpty)
        let data = try? JSONEncoder().encode([item("a", 60)])
        #expect(PendingReports.decode(data).first?.id == "a")
    }

    @Test func theDigestCountsTheLooksWhenTheServerOfTheTunnelWasSilent() {
        let quiet = "2026-10-23 10:00:00 | работает=1ч00м | туннель=вкл:utun4 совпало=да маршрутов=5 рукопожатие=95с | память=120МБ"
        let silent = "2026-10-23 10:05:00 | работает=1ч05м | туннель=вкл:utun4 совпало=да маршрутов=5 рукопожатие=640с | память=120МБ"
        let summary = DailyDigest.summary(lines: [quiet, silent, silent], causes: [])
        #expect(summary.contains("сервер не отвечал: в 2 записях"))
        #expect(!DailyDigest.summary(lines: [quiet], causes: []).contains("сервер не отвечал"))
    }

    @Test func theLineOfTheBlackBoxCarriesTheAgeOfTheAnswerOnlyWhenKnown() {
        var facts = BlackBoxLine.Facts(dns: "выкл", dnsAgrees: true, telegram: "выкл", telegramAgrees: true,
                                       tunnel: "вкл:utun4", tunnelAgrees: true, routes: 5, interface: "utun4", handshakeSeconds: 95)
        #expect(BlackBoxLine.line(now: now, uptime: 60, facts: facts, memoryMegabytes: 100).contains("маршрутов=5 рукопожатие=95с"))
        facts.handshakeSeconds = nil
        #expect(!BlackBoxLine.line(now: now, uptime: 60, facts: facts, memoryMegabytes: 100).contains("рукопожатие"))
    }

    @Test func theCauseThatNewKeysDidNotHelpHasItsWords() {
        #expect(AutoTrigger.newKeysFailed.key == "keys-failed")
        #expect(AutoTrigger.newKeysFailed.title.contains("новые ключи"))
    }

    @Test func aDisagreementOfTheDnsCountsOnlyWhileTheNetAnswers() {
        #expect(AutoReportRules.dnsCounts(agrees: false, online: true) == false, "the net is there: a real disagreement")
        #expect(AutoReportRules.dnsCounts(agrees: false, online: false), "no net: it does not count")
        #expect(AutoReportRules.dnsCounts(agrees: true, online: true))
        var tracker = MismatchTracker()
        let first = tracker.observe("dns", agrees: AutoReportRules.dnsCounts(agrees: false, online: false))
        let second = tracker.observe("dns", agrees: AutoReportRules.dnsCounts(agrees: false, online: false))
        #expect(!first && !second, "an outage never makes the count")
    }

    @Test func theDiaryTellsWhereTheDnsIsNotAsAskedFor() throws {
        let provider = try #require(DNSProvider.all.first)
        let ok = [provider.addresses, provider.addresses]
        #expect(DNSManager.applySummary(provider, services: ["Wi-Fi", "Ethernet"], current: ["Wi-Fi": ok[0], "Ethernet": ok[1]]) == "\(provider.name) задан на 2 из 2 подключений")
        let partial = DNSManager.applySummary(provider, services: ["Wi-Fi", "Ethernet"], current: ["Wi-Fi": ["9.9.9.9"], "Ethernet": provider.addresses])
        #expect(partial == "\(provider.name) задан на 1 из 2 подключений; не так на: Wi-Fi")
        #expect(DNSManager.applySummary(nil, services: ["Wi-Fi"], current: ["Wi-Fi": []]) == "автоматический DNS на 1 из 1 подключений")
        #expect(DNSManager.applySummary(nil, services: ["Wi-Fi", "iPhone USB"], current: ["Wi-Fi": [], "iPhone USB": provider.addresses]).contains("не так на: iPhone USB"))
    }

    @Test func theDigestCountsWhatCameAfterTheLastDigestAndNothingBefore() throws {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let since = try #require(format.date(from: "2026-10-24 12:00:00"))
        let all = [
            "2026-10-24 11:59:59 | работает=1ч | dns=выкл совпало=НЕТ",
            "2026-10-24 12:00:00 | работает=1ч | dns=выкл совпало=НЕТ",
            "2026-10-24 12:00:01 | работает=1ч | dns=выкл совпало=да",
            "2026-10-25 08:00:00 | работает=2ч | dns=выкл совпало=да",
            "строка без времени",
        ]
        let kept = DailyDigest.lines(all, since: since)
        #expect(kept.count == 2, "only what is later than the last digest")
        #expect(kept.first?.hasPrefix("2026-10-24 12:00:01") == true)
        #expect(DailyDigest.lines([], since: since).isEmpty)
        #expect(DailyDigest.lines(all, since: .distantPast).count == 4, "a line with no time is not a line of the box")
    }

    @Test func aTunnelThatGetsNoAnswerIsNotAFaultOfNimbAndIsNotReported() {
        #expect(!AutoReportRules.tunnelErrorIsOurs("сервер не ответил: нет рукопожатия за 16 секунд. Проверьте интернет"), "the network does not let it through")
        #expect(!AutoReportRules.tunnelErrorIsOurs("Туннель остановился сам: его программа неожиданно завершилась."), "it has its own trigger")
        #expect(!AutoReportRules.tunnelErrorIsOurs("Туннель выключился сам: Cloudflare не отвечал несколько минут."))
        #expect(AutoReportRules.tunnelErrorIsOurs("amneziawg-go не запустился (см. /var/run/nimb-tunnel.log)"))
        #expect(AutoReportRules.tunnelErrorIsOurs("Не удалось создать ключи WARP"))
    }

    @Test func theTextOfTheErrorOfAClosedNetworkDoesNotPromiseNewKeys() {
        let text = WarpTunnelModel.friendly(DNSError.failed("сервер не ответил: нет рукопожатия за 16 секунд"))
        #expect(text.contains("рукопожатия"), "the count of failed starts reads these words")
        #expect(text.contains("вуз, работа, отель"))
        #expect(!text.contains("новые ключи"))
        #expect(WarpTunnelModel.friendly(DNSError.failed("нет сокета")) == "нет сокета")
    }

    @Test func theWarningOfAStrictNetworkComesOnlyWhenTheProviderIsSilentAndTheInternetWorks() {
        let text = DNSManager.unreachableWarning(providerName: "GeoHide (EU)", providerAnswers: false, internetWorks: true)
        #expect(text?.hasPrefix(DNSManager.unreachablePrefix) == true)
        #expect(text?.contains("GeoHide (EU)") == true)
        #expect(text?.contains("Выключите «Нейросети»") == true)
        #expect(DNSManager.unreachableWarning(providerName: "GeoHide (EU)", providerAnswers: true, internetWorks: true) == nil)
        #expect(DNSManager.unreachableWarning(providerName: "GeoHide (EU)", providerAnswers: false, internetWorks: false) == nil, "no internet is another trouble")
    }

    @Test func theTunnelIsAdvisedToTelegramOnlyWhenItIsOffAndConnectionsKeepFailing() {
        #expect(TelegramTunnelAdvice.kind(failures: 61, reached: 300, failuresRecently: true, tunnelIsOff: true) == .partly)
        #expect(TelegramTunnelAdvice.kind(failures: 61, reached: 300, failuresRecently: true, tunnelIsOff: false) == nil, "the tunnel is on or being switched")
        #expect(TelegramTunnelAdvice.kind(failures: 61, reached: 300, failuresRecently: false, tunnelIsOff: true) == nil, "the errors have stopped")
        #expect(TelegramTunnelAdvice.kind(failures: 2, reached: 300, failuresRecently: true, tunnelIsOff: true) == nil, "a couple of errors are nothing")
        #expect(TelegramTunnelAdvice.kind(failures: 2, reached: 0, failuresRecently: true, tunnelIsOff: true) == .blocked, "nothing gets through: said at once")
        #expect(TelegramTunnelAdvice.kind(failures: 1, reached: 0, failuresRecently: true, tunnelIsOff: true) == nil, "one failure is not yet a block")
        #expect(TelegramTunnelAdvice.kind(failures: 9, reached: 0, failuresRecently: true, tunnelIsOff: false) == nil)
        #expect(TelegramTunnelAdvice.words(.blocked) != TelegramTunnelAdvice.words(.partly))
    }

    @Test func theHelperOfTheTunnelIsReplacedWhenItIsNotTheOneOfThisApp() {
        #expect(WarpTunnelModel.helperNeedsReplacing(installed: 16, bundled: 18, sameContent: false), "after an update")
        #expect(WarpTunnelModel.helperNeedsReplacing(installed: 22, bundled: 18, sameContent: false), "another build left its own")
        #expect(WarpTunnelModel.helperNeedsReplacing(installed: nil, bundled: 18, sameContent: false))
        #expect(!WarpTunnelModel.helperNeedsReplacing(installed: 18, bundled: 18, sameContent: true))
        #expect(WarpTunnelModel.helperNeedsReplacing(installed: 18, bundled: 18, sameContent: false), "the number of ours, the content of someone else's")
    }

    @Test func aHelperOfAnotherBuildMakesTheBuildNotOurs() {
        #expect(BuildCheck.helperIsForeign(installed: 27, bundled: 19, sameContent: false), "a number the app does not have")
        #expect(BuildCheck.helperIsForeign(installed: 19, bundled: 19, sameContent: false), "our number, other content")
        #expect(!BuildCheck.helperIsForeign(installed: 19, bundled: 19, sameContent: true))
        #expect(!BuildCheck.helperIsForeign(installed: 18, bundled: 19, sameContent: false), "ours from before an update")
        #expect(!BuildCheck.helperIsForeign(installed: nil, bundled: 19, sameContent: false), "no helper yet")
        #expect(!BuildCheck.helperIsForeign(installed: 19, bundled: nil, sameContent: false), "a build without a helper is not judged")
    }

    @Test func onlyASignatureThatIsBrokenMakesTheBuildNotOurs() {
        #expect(BuildCheck.signatureHolds(errSecSuccess))
        #expect(BuildCheck.signatureHolds(errSecCSUnsigned), "a run from the sources")
        #expect(!BuildCheck.signatureHolds(errSecCSSignatureFailed))
        #expect(!BuildCheck.signatureHolds(errSecCSResourcesInvalid))
    }

    @Test func theSignatureOfAReportIsTheSameAsTheRelaysOwn() {
        // The same line and the same key are checked in report-relay/test.mjs: the two sides must give the same letters.
        let message = ReportSigner.message(id: "AB12CD", app: "0.9.23", platform: "macos", install: "ABCD2345", text: "текст")
        #expect(message == "nimb1|AB12CD|0.9.23|macos|ABCD2345|ab15d5ab166623795265154b6c5aea0d7385b6c1c77fe8e5a0b27b7c46bf943e")
        #expect(ReportSigner.signature(of: message, key: Data("test-key".utf8)) == "8d7d8304a9c38885b81822903a8d789248e7b4333623ae5aafadc6d7ceb580e1")
    }

    @Test func onlyTheLatestVersionMayReport() {
        #expect(ReportFreshness.isOutdated(current: "0.9.22", latest: "0.9.23"))
        #expect(ReportFreshness.isOutdated(current: "0.9.9", latest: "0.9.10"), "ten is more than nine")
        #expect(!ReportFreshness.isOutdated(current: "0.9.23", latest: "0.9.23"))
        #expect(!ReportFreshness.isOutdated(current: "0.9.24", latest: "0.9.23"), "a build before its release is not old")
        #expect(!ReportFreshness.isOutdated(current: "0.9.22", latest: nil), "nothing is known: no answer of the update check yet")
        let words = ReportGate.outdatedWords(latest: "0.9.23")
        #expect(words.contains("0.9.23") && words.contains("Обновите Nimb"))
        #expect(!ReportGate.outdatedWords(latest: nil).contains("  "))
    }

    @Test func aChangedBuildSaysSoOnTheLineOfTheSwitch() {
        #expect(ReportGate.shortWords(modified: true) == "Тестирование приостановлено: сборка изменена.")
    }

    @Test func theKeyIsMixedWithTheVersionAndComesBackWithIt() {
        let key = Array("0123456789abcdef0123456789abcdef".utf8)
        let mixed = ReportKey.unmixed(key, withVersion: "0.9.23")
        #expect(mixed != key, "the line of the key is not there as it is")
        #expect(ReportKey.unmixed(mixed, withVersion: "0.9.23") == key)
        #expect(ReportKey.unmixed(mixed, withVersion: "0.9.24") != key, "another version does not open it")
        #expect(ReportKey.unmixed(key, withVersion: "").isEmpty)
    }

    @Test func aBuildWithoutTheKeyOfAReleaseSendsNothing() async {
        #expect(ReportKey.data == nil, "the tests are built from the sources")
        #expect(BuildCheck.problem == "собрано не из официального выпуска")
        #expect(!ReportConfig.canSend)
        do {
            try await ReportSender.send(id: "AB12CD", text: "text")
            Issue.record("a build without the key must not send")
        } catch let failure as ReportSender.Failure {
            #expect(failure.refused, "not kept for another try")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func aLimitOfGitHubOrNoNetworkIsNotAFailedCheckOfUpdates() {
        #expect(!UpdateError.countsAsFailedCheck(UpdateError("GitHub ограничил число запросов", isRateLimit: true)))
        #expect(UpdateError.countsAsFailedCheck(UpdateError("GitHub не отдал информацию о релизе.")))
        #expect(!UpdateError.countsAsFailedCheck(URLError(.notConnectedToInternet)))
        #expect(!UpdateError.countsAsFailedCheck(URLError(.networkConnectionLost)))
        #expect(UpdateError.countsAsFailedCheck(URLError(.cannotFindHost)), "GitHub itself unreachable is still worth a report")
    }

    @Test func thePasswordlessRuleNeedsEveryFolderToTheHelperToBeRootsAlone() {
        #expect(WarpPaths.isSafeFolder(owner: 0, permissions: 0o755))
        #expect(!WarpPaths.isSafeFolder(owner: 501, permissions: 0o755), "the person owns it: he can swap what is in it")
        #expect(!WarpPaths.isSafeFolder(owner: 0, permissions: 0o775), "the group may write")
        #expect(!WarpPaths.isSafeFolder(owner: 0, permissions: 0o777), "everybody may write")
        let ours: [String: (owner: Int, permissions: Int)] = ["/usr": (0, 0o755), "/usr/local": (501, 0o755), "/usr/local/libexec": (0, 0o755)]
        #expect(WarpPaths.unsafeFolder(attributes: { ours[$0] }) == "/usr/local", "after a chown of /usr/local")
        let fine: [String: (owner: Int, permissions: Int)] = ["/usr": (0, 0o755), "/usr/local": (0, 0o755), "/usr/local/libexec": (0, 0o755)]
        #expect(WarpPaths.unsafeFolder(attributes: { fine[$0] }) == nil, "the folder of the helper is not there yet: the installation makes it as root")
    }

    @Test func aFailedInstallationOfAnUpdateHasItsOwnCauseNamedByTheStage() {
        let trigger = AutoTrigger.updateInstall("Проверка подписи")
        #expect(trigger.key == "update-install")
        #expect(trigger.title == "установка обновления не удалась на этапе «Проверка подписи»")
    }

    @Test func theRulesOfAgreement() {
        #expect(AutoReportRules.tunnelAgrees(on: true, routes: 5, viaTunnel: true))
        #expect(!AutoReportRules.tunnelAgrees(on: true, routes: 0, viaTunnel: false))
        #expect(AutoReportRules.tunnelAgrees(on: false, routes: 0, viaTunnel: false))
        #expect(!AutoReportRules.tunnelAgrees(on: false, routes: 3, viaTunnel: true), "routes left behind")
        #expect(AutoReportRules.tunnelAgrees(on: false, routes: 0, viaTunnel: true), "another VPN carries the traffic: not a fault of ours")
        #expect(AutoReportRules.tunnelAgrees(on: false, routes: 5, viaTunnel: true, working: true), "being switched on: the routes are coming")
        #expect(AutoReportRules.telegramAgrees(running: false, listening: false))
        #expect(!AutoReportRules.telegramAgrees(running: false, listening: true), "the port is held while it is off")
        #expect(AutoReportRules.telegramAgrees(running: true, listening: true), "failed connections are the network's, not a fault of Nimb")
        #expect(!AutoReportRules.telegramAgrees(running: true, listening: false), "on, but nobody listens")
    }

    @Test func causesHaveKeysAndWords() {
        #expect(AutoTrigger.mismatch(.telegram).key == "mismatch-telegram")
        #expect(AutoTrigger.error(.tunnel).key == "error-tunnel")
        #expect(AutoTrigger.error(.tunnel).title.contains("YouTube и Discord"))
        for trigger in [AutoTrigger.previousEndedBadly, .tunnelRestarted, .tunnelDropped, .mismatch(.dns), .error(.dns), .updateCheck, .tunnelSilent, .newKeysFailed, .dailyDigest] {
            #expect(trigger.key.range(of: "^[A-Za-z0-9:-]{1,40}$", options: .regularExpression) != nil, "the relay takes plain letters in a key")
        }
        #expect(AutoTrigger.previousEndedBadly.key == "crash")
        #expect(AutoTrigger.tunnelDropped.title.contains("не запустился снова"))
        #expect(AutoReporter.newInstallID().count == 8)
    }
}
