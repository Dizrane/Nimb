import CryptoKit
import Foundation

/// The key that signs reports: the key of this version, made from the master key by `scripts/report_key.py` (the relay makes the same one from the
/// version a report names), so what is taken out of a release signs that version only. It is not in the repository: the script of a release
/// (`scripts/build_app.sh`) writes it into a file that sits next to this one for the time of the build and nowhere else, and the build is given
/// `OFFICIAL_BUILD`. A build from the sources has no key, so the
/// relay would turn its reports away, and the program does not send them at all (see `BuildCheck`). In the program the key is not a line of
/// text that a search of the file would show: the script mixes it with the version of the build, and it is told apart at the moment of use.
/// That is no lock against a person who sets out to take it from a release (nothing in a program a person owns is); the lock is the relay's,
/// which turns the key off when it is taken.
enum ReportKey {
    #if OFFICIAL_BUILD
    static var bytes: [UInt8] { unmixed(officialReportKey, withVersion: Updater.currentVersion) }
    #else
    static var bytes: [UInt8] { [] }
    #endif

    static var data: Data? { bytes.isEmpty ? nil : Data(bytes) }

    /// The same for mixing and for telling apart: each byte with the byte of the version, round and round.
    static func unmixed(_ mixed: [UInt8], withVersion version: String) -> [UInt8] {
        let pad = Array(version.utf8)
        return pad.isEmpty ? [] : mixed.enumerated().map { $0.element ^ pad[$0.offset % pad.count] }
    }
}

/// The signature the relay checks (`report-relay/index.js`, `signatureOk`): HMAC-SHA256 over the report's number, version, platform,
/// installation and the hash of its text, in hex. The two sides build the same line.
enum ReportSigner {
    static func message(id: String, app: String, platform: String, install: String, text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["nimb1", id, app, platform, install, hash].joined(separator: "|")
    }

    static func signature(of message: String, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
}
