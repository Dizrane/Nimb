import Foundation

/// Removes the app together with everything it has left on the Mac. DNS and the sudoers rule are handled by
/// `DNSManager` before this; this part only deletes files, after the app has quit.
enum Uninstaller {
    /// Both names the app has had.
    static let identifiers = ["com.nimb.app", "com.rdns.app"]

    /// Why the app cannot delete itself, or nil if it can.
    static func blocker() -> String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return "Nimb запущен не как приложение (.app), удалять нечего." }
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
        var result = [bundle.path]

        let folders = Set([bundle.deletingLastPathComponent().path, "/Applications", "\(home)/Applications"])
        for folder in folders.sorted() {
            for name in ["Nimb.app", "RDNS.app"] {
                let path = "\(folder)/\(name)"
                guard path != bundle.path, fm.fileExists(atPath: path),
                      let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist"),
                      let id = info["CFBundleIdentifier"] as? String, identifiers.contains(id) else { continue }
                result.append(path)
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

        let temp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("Nimb-update-") {
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
