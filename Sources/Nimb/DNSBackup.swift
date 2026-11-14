import Foundation

/// The first settings belong to the person; attempted writes remain recorded even if a command or the app stops halfway.
struct DNSBackup: Codable {
    struct Entry: Codable {
        var name: String
        var servers: [String]
        var applied: [[String]]
    }
    var restored: [String: [String]]? // Distinguish a restored/manual provider from DNS enabled by Nimb.
    var entries: [String: Entry] = [:] // SystemConfiguration service UUID, stable across renaming.

    mutating func prepare(_ provider: DNSProvider, current: [String: DNSServiceSettings]) {
        for (id, state) in current {
            restored?[id] = nil
            var saved = entries[id] ?? Entry(name: state.name, servers: state.servers, applied: [])
            if !saved.applied.contains(where: { DNSManager.sameServers($0, state.servers) }),
               !DNSManager.sameServers(saved.servers, state.servers) {
                // An explicit new enable after a manual change starts from that person's newer settings.
                saved.servers = state.servers
                saved.applied = []
            }
            saved.name = state.name
            if !saved.applied.contains(provider.addresses) { saved.applied.append(provider.addresses) }
            entries[id] = saved
        }
    }

    func restoration(current: [String: DNSServiceSettings], legacyServices: Set<String>) -> [String: [String]] {
        var targets: [String: [String]] = [:]
        for (id, state) in current {
            if let saved = entries[id] {
                if saved.applied.contains(where: { DNSManager.sameServers($0, state.servers) }) { targets[id] = saved.servers }
            } else if !isRestored(id: id, servers: state.servers), legacyServices.contains(state.name), DNSProvider.all.contains(where: { $0.matches(state.servers) }) {
                targets[id] = [] // Settings changed by older versions cannot be reconstructed.
            }
        }
        return targets
    }

    func isRestored(id: String, servers: [String]) -> Bool {
        restored?[id].map { DNSManager.sameServers($0, servers) } ?? false
    }

    mutating func reconcile(current: [String: DNSServiceSettings]) {
        for (id, saved) in entries {
            guard let state = current[id] else { continue } // A removed USB service may return later.
            let original = DNSManager.sameServers(state.servers, saved.servers)
            let stillOurs = saved.applied.contains { DNSManager.sameServers($0, state.servers) }
            if original || !stillOurs {
                if restored == nil { restored = [:] }
                restored?[id] = state.servers
                entries[id] = nil
            }
        }
    }

}

struct DNSServiceSettings {
    let name: String
    let servers: [String]
}

/// Save atomically before changing DNS. A corrupt/unreadable backup must never be mistaken for an empty one.
struct DNSBackupStore {
    let url: URL

    static var standard: DNSBackupStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DNSBackupStore(url: root.appendingPathComponent("com.nimb.app/dns-backup.json"))
    }

    func load() throws -> DNSBackup {
        do {
            return try JSONDecoder().decode(DNSBackup.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return DNSBackup()
        }
    }

    func save(_ backup: DNSBackup) throws {
        let fm = FileManager.default
        if backup.entries.isEmpty && (backup.restored?.isEmpty ?? true) {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
