import Foundation

/// Removes the app together with everything it has left on the Mac. DNS and the sudoers rule are handled by
/// `DNSManager` before this; this part only deletes files, after the app has quit.
enum Uninstaller {
    /// Both names the app has had.
    static let identifiers = ["com.nimb.app", "com.rdns.app"]

    /// The running copy is not the one on disk: macOS opens a downloaded app from a temporary read-only copy (App Translocation), and a
    /// disk image is read-only too. There is nothing to delete at that place: the real copies are looked for in the usual folders.
    static var runsFromTemporaryPlace: Bool {
        let path = Bundle.main.bundleURL.path
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// Why the app cannot delete itself, or nil if it can.
    static func blocker() -> String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return "Nimb запущен не как приложение (.app), удалять нечего." }
        if runsFromTemporaryPlace { return nil }
        let folder = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else {
            return "У Nimb нет права записи в «\(folder)», поэтому он не может удалить сам себя. Перетащите его в Корзину вручную."
        }
        return nil
    }

    /// Everything that gets deleted: the app (and an old RDNS.app or Nimb.app of ours next to it), its settings, caches
    /// and the leftovers of an interrupted update.
    static func paths() -> [String] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let bundle = Bundle.main.bundleURL
        var result = runsFromTemporaryPlace ? [] : [bundle.path]

        // The copies of the app: next to the running one (by its usual names), and in the places where people keep an app they have
        // downloaded (any name there: «Nimb 2.app» is what a second download is called).
        func isOurs(_ path: String) -> Bool {
            guard let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist"), let id = info["CFBundleIdentifier"] as? String else { return false }
            return identifiers.contains(id)
        }
        if !runsFromTemporaryPlace {
            let folder = bundle.deletingLastPathComponent().path
            for name in ["Nimb.app", "RDNS.app"] {
                let path = "\(folder)/\(name)"
                if path != bundle.path, fm.fileExists(atPath: path), isOurs(path) { result.append(path) }
            }
        }
        for folder in ["/Applications", "\(home)/Applications", "\(home)/Downloads", "\(home)/Desktop"] {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                let path = "\(folder)/\(name)"
                if !result.contains(path), path != bundle.path, isOurs(path) { result.append(path) }
            }
        }

        for id in identifiers {
            result += [
                "\(home)/Library/Preferences/\(id).plist",
                "\(home)/Library/Caches/\(id)",
                "\(home)/Library/HTTPStorages/\(id)",
                "\(home)/Library/HTTPStorages/\(id).binarycookies",
                "\(home)/Library/Saved Application State/\(id).savedState",
                "\(home)/Library/Application Support/\(id)",
                "\(home)/Library/WebKit/\(id)",
            ]
        }
        // The diary of the app (`AppLog`).
        result.append("\(home)/Library/Logs/Nimb")

        let temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("Nimb-update-") || name.hasPrefix("Nimb-move-") {
            result.append(temp.appendingPathComponent(name).path)
        }
        return result
    }

    /// Starts a helper that waits for this process to quit and then deletes `paths()`. The caller quits the app.
    static func scheduleRemoval() throws {
        let script = """
        #!/bin/sh
        PID="$1"; shift
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        for id in \(identifiers.joined(separator: " ")); do defaults delete "$id" 2>/dev/null; done
        for path in "$@"; do rm -rf "$path"; done
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-uninstall-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier)] + paths()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
