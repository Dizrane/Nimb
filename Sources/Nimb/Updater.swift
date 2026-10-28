import CryptoKit
import Foundation

struct Release: Equatable {
    let version: String
    let assetName: String
    let zipURL: URL
    /// SHA-256 of the zip, taken from the release description.
    let sha256: String?
    let pageURL: URL
    /// The signature of the zip, an asset next to it (`<zip name>.sig`). The hash in the notes only shows that the file came whole: it lives
    /// where the zip lives, and whoever can change the one can change the other. The signature cannot be made without the private key.
    var signatureURL: URL? = nil
}

struct UpdateError: LocalizedError {
    let message: String
    /// GitHub turned the request away because too many came from this address (Cloudflare WARP, which Nimb turns on, is one address for many).
    let isRateLimit: Bool
    init(_ message: String, isRateLimit: Bool = false) { self.message = message; self.isRateLimit = isRateLimit }
    var errorDescription: String? { message }

    /// Whether a failed check counts towards the automatic report «updates cannot be checked»: a limit of GitHub is not Nimb's to mend.
    static func countsAsFailedCheck(_ error: Error) -> Bool { !((error as? UpdateError)?.isRateLimit ?? false) }
}

/// Checks GitHub for a newer release and replaces the running app with it.
enum Updater {
    static let repository = "Dizrane/Nimb"
    static let bundleIdentifier = "com.nimb.app"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Checking

    struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
        let draft: Bool?
        let prerelease: Bool?
    }

    /// The newest release for the Mac. The repository also holds releases of the Windows version (`windows-v…`), so "the latest release" of
    /// GitHub is not enough: it is whichever of them was made last. The list is read and the releases that are not for the Mac are left out.
    ///
    /// GitHub's API lets 60 requests an hour through for one address, and many people share an address (a VPN, the exit of Cloudflare
    /// WARP, which Nimb itself turns on), so when the API refuses, the pages of the release are read instead: they have no such limit.
    static func latestRelease() async throws -> Release {
        do {
            return try await latestFromAPI()
        } catch {
            if let release = try? await latestFromReleasePage() { return release }
            throw error
        }
    }

    private static func latestFromAPI() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            throw UpdateError(status == 403 || status == 429
                ? "GitHub ограничил число запросов с вашего адреса. Попробуйте через несколько минут."
                : "GitHub не отдал информацию о релизе.", isRateLimit: status == 403 || status == 429)
        }
        guard let release = newestForMac(in: try JSONDecoder().decode([GitHubRelease].self, from: data)) else {
            throw UpdateError("На GitHub нет релиза Nimb для Mac с файлом Nimb-*.zip.")
        }
        return release
    }

    /// A tag of a release for the Mac: `v0.9.9`. Not `windows-v0.1.0`, not a version with a word after it.
    static func isMacTag(_ tag: String) -> Bool {
        tag.range(of: #"^[vV]?[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func isMacArchive(_ name: String) -> Bool { name.hasPrefix("Nimb") && name.hasSuffix(".zip") }

    /// Published, not a pre-release, a tag of the Mac, and the archive is there.
    static func isForMac(_ release: GitHubRelease) -> Bool {
        release.draft != true && release.prerelease != true && isMacTag(release.tag_name) && release.assets.contains { isMacArchive($0.name) }
    }

    /// The release with the highest version among those for the Mac (not the first in the list: the order is the order of making them).
    static func newestForMac(in releases: [GitHubRelease]) -> Release? {
        let best = releases.filter(isForMac).reduce(nil as GitHubRelease?) { best, next in
            guard let best else { return next }
            return isNewer(next.tag_name, than: best.tag_name) ? next : best
        }
        guard let best, let asset = best.assets.first(where: { isMacArchive($0.name) }) else { return nil }
        let body = best.body ?? ""
        return Release(
            version: best.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            assetName: asset.name,
            zipURL: asset.browser_download_url,
            sha256: sha256(for: asset.name, in: body) ?? firstSHA256(in: body),
            pageURL: best.html_url,
            signatureURL: best.assets.first(where: { $0.name == asset.name + ".sig" })?.browser_download_url
        )
    }

    /// The same from the web pages: the feed of releases names the tags (the newest of the Mac's is taken), and the page of that release
    /// has the archive and, in its description, the hash on the line with the file name (`Nimb-<version>.zip`).
    static func latestFromReleasePage() async throws -> Release {
        let tag = try await newestMacTag()
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let page = http.url else {
            throw UpdateError("GitHub не отдал страницу релиза.")
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let name = "Nimb-\(version).zip"
        let html = String(decoding: data, as: UTF8.self)
        guard html.contains(name), let zip = URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)") else {
            throw UpdateError("На странице релиза нет файла \(name).")
        }
        let signature = html.contains(name + ".sig") ? URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name).sig") : nil
        return Release(version: version, assetName: name, zipURL: zip, sha256: sha256(for: name, in: html), pageURL: page, signatureURL: signature)
    }

    /// The newest tag of the Mac in the feed of releases; if the feed cannot be read, the one that `/releases/latest` leads to, when it is a
    /// tag of the Mac.
    private static func newestMacTag() async throws -> String {
        var feed = URLRequest(url: URL(string: "https://github.com/\(repository)/releases.atom")!)
        feed.timeoutInterval = 15
        if let (data, response) = try? await URLSession.shared.data(for: feed), (response as? HTTPURLResponse)?.statusCode == 200,
           let tag = newestMacTag(inFeed: String(decoding: data, as: UTF8.self)) {
            return tag
        }
        var latest = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        latest.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: latest)
        if let path = (response as? HTTPURLResponse)?.url?.path, let marker = path.range(of: "/releases/tag/"),
           isMacTag(String(path[marker.upperBound...])) {
            return String(path[marker.upperBound...])
        }
        throw UpdateError("GitHub не отдал страницу релиза.")
    }

    /// The tags in an Atom feed of releases (`…/releases/tag/<tag>`), the newest of those of the Mac by version.
    static func newestMacTag(inFeed feed: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/releases/tag/([^"?#/<>\s]+)"#) else { return nil }
        let tags = regex.matches(in: feed, range: NSRange(feed.startIndex..., in: feed)).compactMap { match in
            Range(match.range(at: 1), in: feed).map { String(feed[$0]) }
        }.filter(isMacTag)
        return tags.reduce(nil as String?) { best, next in
            guard let best else { return next }
            return isNewer(next, than: best) ? next : best
        }
    }

    /// The hash written on the same line as the file name, lowercased: the notes list one "hash  file" line per archive.
    static func sha256(for assetName: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains(assetName) {
            if let hash = firstSHA256(in: String(line)) { return hash }
        }
        return nil
    }

    /// First 64-digit hex string in the text, lowercased.
    static func firstSHA256(in text: String) -> String? {
        guard let range = text.range(of: "[0-9a-fA-F]{64}", options: .regularExpression) else { return nil }
        return text[range].lowercased()
    }

    /// Compares dotted numeric versions: "0.1.10" is newer than "0.1.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// The public keys the updates are signed with (Ed25519, 32 bytes, base64). The private one stays with the maker of the releases, off the net
    /// (`scripts/sign_release.swift`). More than one is allowed, so that a key can be replaced: the app with the new key goes out first.
    static let trustedKeys = ["A8Hv9MEsL+jtyYnniwH1PART5CiHUZqgJofpqRz/ttE="]

    /// Whether `signature` (the text of the `.sig` file: base64) is a signature of `data` made by one of the keys.
    static func isSigned(_ data: Data, signature text: String, keys: [String] = trustedKeys) -> Bool {
        guard let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return keys.contains { key in
            guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return publicKey.isValidSignature(signature, for: data)
        }
    }

    /// Downloads and verifies the release, then starts a helper that swaps the app after this process exits.
    /// The caller must quit the app once this returns.
    static func install(_ release: Release, status: @escaping @Sendable (String) -> Void) async throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw UpdateError("Обновление работает только из собранного приложения Nimb.")
        }
        guard !target.path.contains("/AppTranslocation/") else {
            throw UpdateError("macOS запустил приложение из временной копии. Переместите Nimb в «Программы» и откройте оттуда.")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("Нет прав на запись в «\(target.deletingLastPathComponent().path)». Переместите приложение в «Программы» или обновите вручную.")
        }
        guard let expected = release.sha256 else {
            throw UpdateError("В описании релиза нет SHA-256, установка отменена.")
        }

        status("Загрузка…")
        let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Не удалось скачать \(release.zipURL.lastPathComponent).")
        }
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let zip = stage.appendingPathComponent("Nimb.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        status("Проверка подписи…")
        guard let signatureURL = release.signatureURL else {
            throw UpdateError("У этого релиза нет подписи, установка отменена. Скачайте обновление вручную со страницы релиза.")
        }
        let (signatureData, signatureResponse) = try await URLSession.shared.data(from: signatureURL)
        guard (signatureResponse as? HTTPURLResponse)?.statusCode == 200,
              isSigned(try Data(contentsOf: zip), signature: String(decoding: signatureData, as: UTF8.self)) else {
            throw UpdateError("Подпись не подошла: это обновление сделано не автором Nimb. Установка отменена.")
        }

        status("Проверка…")
        let newApp = try verifyAndUnpack(zip: zip, expectedSHA256: expected, version: release.version, into: stage)

        status("Установка…")
        try launchInstaller(newApp: newApp, target: target, stage: stage)
    }

    /// Checks the hash and the bundle itself; returns the unpacked app.
    static func verifyAndUnpack(zip: URL, expectedSHA256: String, version: String, into stage: URL) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256.lowercased() else {
            throw UpdateError("SHA-256 скачанного файла не совпадает с указанным в релизе. Установка отменена.")
        }

        let unpacked = stage.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError("В архиве нет приложения.")
        }
        guard let identifier = info["CFBundleIdentifier"] as? String, identifier == bundleIdentifier else {
            throw UpdateError("В архиве не то приложение (другой идентификатор).")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("Версия в архиве не совпадает с версией релиза.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    /// The helper waits for this process to quit, replaces the app in place, keeping the old bundle until the copy
    /// has succeeded, then reopens the app and removes the staging folder.
    private static func launchInstaller(newApp: URL, target: URL, stage: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; TARGET="$2"; NEW="$3"; STAGE="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$TARGET.old"
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP"; then
            if /usr/bin/ditto "$NEW" "$TARGET"; then
                xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
                rm -rf "$BACKUP"
            else
                rm -rf "$TARGET"
                mv "$BACKUP" "$TARGET"
            fi
        fi
        open "$TARGET"
        rm -rf "$STAGE"
        """
        let scriptURL = stage.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path, stage.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError(message.isEmpty ? "\(URL(fileURLWithPath: path).lastPathComponent) завершился с ошибкой." : message)
        }
    }
}
