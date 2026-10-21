import CryptoKit
import Foundation

/// Files that root is going to put in place, kept for a moment in a folder of the person (root cannot read the app itself when it sits
/// in Desktop or Documents). Any program of the person can change a file in that folder while the password is being typed, so root does
/// not install from it: it first copies the files into a folder of its own and compares the copies with the hashes made here, from the
/// very bytes that were written. A file that changed on the way stops the installation before anything is touched.
struct StagedFiles {
    let folder: URL
    let hashes: [(name: String, sha256: String)]

    init(_ files: [(name: String, data: Data)]) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-warp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var made: [(name: String, sha256: String)] = []
        for file in files {
            try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
            made.append((file.name, SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()))
        }
        hashes = made
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// The lines of the script of root that come first: afterwards `"$stage"` is a folder that only root can enter, holding copies of the
    /// files that have been checked, and it is removed when the script ends. `base` is where root keeps it (a test uses another place).
    func guardedCopy(into base: String = "/var/run") -> [String] {
        var lines = [
            "stage=$(/usr/bin/mktemp -d '\(base)/nimb-install.XXXXXX')",
            "trap '/bin/rm -rf \"$stage\"' EXIT",
        ]
        lines += hashes.map { "/bin/cp '\(folder.path)/\($0.name)' \"$stage/\($0.name)\"" }
        lines += hashes.map {
            "[ \"$(/usr/bin/shasum -a 256 \"$stage/\($0.name)\" | /usr/bin/cut -d' ' -f1)\" = '\($0.sha256)' ] || { echo 'Файлы для установки изменились по дороге, ничего не установлено.' >&2; exit 1; }"
        }
        return lines
    }
}
