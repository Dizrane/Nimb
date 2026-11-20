import Foundation
import Testing
@testable import Nimb

@Suite struct LegacyGeoHideHostsTests {
    @Test func removesOnlyItsOwnBlockAndRestoresOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let original = Data("\u{FEFF}# existing\r\n127.0.0.1 localhost\r\n192.0.2.1 other.test".utf8)
        let block = [LegacyGeoHideHosts.start, "192.0.2.2 old.test", LegacyGeoHideHosts.end, ""].joined(separator: "\r\n")
        try (Data("\u{FEFF}".utf8) + Data(block.utf8) + original.dropFirst(3)).write(to: file)
        try DNSManager.run("/bin/sh", ["-c", LegacyGeoHideHosts.removalCommand(path: file.path)])
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func refusesToDeleteAnIncompleteBlock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let original = "\(LegacyGeoHideHosts.start)\n192.0.2.1 other.test\n"
        try Data(original.utf8).write(to: file)
        #expect(throws: DNSError.self) {
            try DNSManager.run("/bin/sh", ["-c", LegacyGeoHideHosts.removalCommand(path: file.path)])
        }
        #expect(try Data(contentsOf: file) == Data(original.utf8))
    }
}
