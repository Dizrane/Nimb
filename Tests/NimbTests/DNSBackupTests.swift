import Foundation
import Testing
@testable import Nimb

@Suite struct DNSBackupTests {
    private let first = DNSProvider.all[0], second = DNSProvider.all[1]
    private func state(_ name: String, _ servers: [String]) -> DNSServiceSettings { DNSServiceSettings(name: name, servers: servers) }

    @Test func originalIPv4IPv6AndAutomaticSurviveProviderChangesAndARestart() throws {
        var backup = DNSBackup()
        let original = ["9.9.9.9", "fdab::53"]
        backup.prepare(first, current: ["wifi": state("Wi-Fi", original), "lan": state("Ethernet", [])])
        backup.prepare(second, current: ["wifi": state("Wi-Fi", first.addresses), "lan": state("Ethernet", first.addresses)])
        let loaded = try JSONDecoder().decode(DNSBackup.self, from: JSONEncoder().encode(backup))
        // One write succeeded and the other failed: both possible owners must still be recognised.
        let plan = loaded.restoration(current: ["wifi": state("Renamed Wi-Fi", second.addresses), "lan": state("Ethernet", first.addresses)], legacyServices: [])
        #expect(plan["wifi"] == original)
        #expect(plan["lan"] == [])
        #expect(loaded.entries["wifi"]?.servers == original)
    }

    @Test func partialRestorationKeepsFailedAndAbsentConnectionsButPreservesManualDNS() {
        var backup = DNSBackup()
        let original = ["10.0.0.53"]
        backup.prepare(first, current: ["wifi": state("Wi-Fi", original), "usb": state("USB", []), "manual": state("Ethernet", [])])
        let now = ["wifi": state("Wi-Fi", first.addresses), "manual": state("Ethernet", ["10.0.0.99"])]
        #expect(backup.restoration(current: now, legacyServices: ["Wi-Fi", "Ethernet"])["manual"] == nil)
        backup.reconcile(current: now)
        #expect(Set(backup.entries.keys) == ["wifi", "usb"])
        backup.reconcile(current: ["wifi": state("Wi-Fi", original)])
        #expect(Set(backup.entries.keys) == ["usb"])
        let returning = ["usb": state("Renamed USB", first.addresses)]
        #expect(backup.restoration(current: returning, legacyServices: [])["usb"] == [])
        backup.reconcile(current: ["usb": state("Renamed USB", [])])
        #expect(backup.entries.isEmpty)
    }

    @Test func enablingAfterAManualChangeSavesTheNewOriginal() {
        var backup = DNSBackup()
        backup.prepare(first, current: ["wifi": state("Wi-Fi", [])])
        backup.prepare(second, current: ["wifi": state("Wi-Fi", ["10.0.0.99"])])
        #expect(backup.restoration(current: ["wifi": state("Wi-Fi", second.addresses)], legacyServices: [])["wifi"] == ["10.0.0.99"])
    }

    @Test func legacyFallbackLeavesUnrecognisedCustomDNSAlone() {
        let plan = DNSBackup().restoration(current: ["wifi": state("Wi-Fi", first.addresses), "lan": state("Ethernet", ["10.0.0.53"])], legacyServices: ["Wi-Fi", "Ethernet"])
        #expect(plan["wifi"] == [])
        #expect(plan["lan"] == nil)
    }

    @Test func persistenceIsPrivateAndCorruptionDoesNotBecomeAnEmptyBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DNSBackupStore(url: folder.appendingPathComponent("dns.json"))
        #expect(try store.load().entries.isEmpty)
        var backup = DNSBackup()
        backup.prepare(first, current: ["wifi": state("Wi-Fi", ["9.9.9.9"])])
        try store.save(backup)
        #expect(try store.load().entries["wifi"]?.servers == ["9.9.9.9"])
        #expect(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int == 0o600)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        try store.save(DNSBackup())
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func readsIPv6StartingWithALetterAndRejectsUnknownToolOutput() throws {
        #expect(try DNSManager.parsedServers("9.9.9.9\nfdab::53\nfe80::1%en0\n") == ["9.9.9.9", "fdab::53", "fe80::1%en0"])
        #expect(try DNSManager.parsedServers("There aren't any DNS Servers set on Wi-Fi.\n") == [])
        #expect(throws: (any Error).self) { try DNSManager.parsedServers("An Error occurred: invalid service.") }
        #expect(DNSManager.sameServers(["fdab:0:0:0:0:0:0:53"], ["fdab::53"]))
    }

    @Test func restoredAddressesAndServiceNamesAreShellQuoted() {
        let script = DNSManager.settingsScript(["Wi-Fi'; echo BAD": ["fdab::53", "9.9.9.9"]])
        #expect(script.contains("'Wi-Fi'\\''; echo BAD' 'fdab::53' '9.9.9.9'"))
        #expect(!script.contains("NOPASSWD"))
    }
}

@Suite struct RestoredProviderDNSTests {
    @Test func anOriginalProviderDoesNotBecomeOwnedAgainAfterRestoring() {
        let original = DNSProvider.all[0], enabled = DNSProvider.all[1]
        var backup = DNSBackup()
        backup.prepare(enabled, current: ["wifi": DNSServiceSettings(name: "Wi-Fi", servers: original.addresses)])
        backup.reconcile(current: ["wifi": DNSServiceSettings(name: "Wi-Fi", servers: original.addresses)])
        #expect(backup.entries.isEmpty)
        #expect(backup.restoration(current: ["wifi": DNSServiceSettings(name: "Wi-Fi", servers: original.addresses)], legacyServices: ["Wi-Fi"]).isEmpty)
        let state = DNSConfiguration(services: ["Wi-Fi"], servers: ["Wi-Fi": original.addresses], restoredServices: ["Wi-Fi"])
        #expect(state.active == nil && !state.needsCleanup)
        // A new explicit enable owns the provider again.
        backup.prepare(enabled, current: ["wifi": DNSServiceSettings(name: "Wi-Fi", servers: original.addresses)])
        #expect(!backup.isRestored(id: "wifi", servers: original.addresses))
    }
}

@Suite struct DNSUninstallDataTests {
    @Test func theDNSBackupIsInsideTheDataRemovedByTheMacUninstaller() {
        let backup = DNSBackupStore.standard.url.path
        #expect(Uninstaller.paths().contains { backup.hasPrefix($0 + "/") })
    }
}
