import CryptoKit
import Foundation

struct Release: Equatable {
    let version: String
    let assetName: String
    let zipURL: URL
    /// SHA-256 of the zip, taken from the release description.
    let sha256: String?
    let pageURL: URL
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Checks GitHub for a newer release and replaces the running app with it.
enum Updater {
    static let repository = "Dizrane/Nimb"
    static let bundleIdentifier = "com.nimb.app"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Checking

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub не отдал информацию о релизе.")
        }
        let github = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = github.assets.first(where: { $0.name.hasPrefix("Nimb") && $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("В последнем релизе нет файла Nimb-*.zip.")
        }
        let body = github.body ?? ""
        return Release(
            version: github.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            assetName: asset.name,
            zipURL: asset.browser_download_url,
            sha256: sha256(for: asset.name, in: body) ?? firstSHA256(in: body),
            pageURL: github.html_url
        )
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
