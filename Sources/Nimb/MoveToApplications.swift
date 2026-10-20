import AppKit

/// Offers to move the app into «Программы» when it is started from Downloads, the Desktop or a disk image.
/// There the app cannot update itself, and macOS may run it from a temporary copy that disappears on quit.
@MainActor
enum MoveToApplications {
    private static let declinedKey = "moveToApplicationsDeclined"

    /// Where the app is installed; the environment variable exists for testing the move in a scratch folder.
    private static var applicationsFolder: String {
        ProcessInfo.processInfo.environment["NIMB_APPLICATIONS_DIR"] ?? "/Applications"
    }

    private static var shouldOffer: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !UserDefaults.standard.bool(forKey: declinedKey) else { return false }
        let home = NSHomeDirectory()
        let folder = bundle.deletingLastPathComponent().path
        guard folder != applicationsFolder, folder != home + "/Applications",
              FileManager.default.isWritableFile(atPath: applicationsFolder) else { return false }

        // A build inside a source checkout is a developer's own business.
        var parent = bundle.deletingLastPathComponent()
        while parent.path.count > home.count, parent.path.hasPrefix(home) {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) { return false }
            parent = parent.deletingLastPathComponent()
        }

        let path = bundle.path
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
            || path.hasPrefix(home + "/Downloads/") || path.hasPrefix(home + "/Desktop/")
    }

    static func offer() {
        guard shouldOffer else { return }
        let alert = NSAlert()
        alert.messageText = "Переместить Nimb в «Программы»?"
        alert.informativeText = "Оттуда приложение сможет обновляться само, и его проще найти. Если в «Программах» уже есть Nimb, он будет заменён."
        alert.addButton(withTitle: "Переместить")
        alert.addButton(withTitle: "Не сейчас")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Больше не спрашивать"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: declinedKey) }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try move()
            AppDelegate.quit(stoppingServices: false)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Не удалось переместить Nimb"
            failure.informativeText = "\(error.localizedDescription)\nПеретащите Nimb.app в «Программы» вручную."
            failure.runModal()
        }
    }

    /// Copies the app now (the temporary copy is gone once the app quits), then a helper puts the copy in place after
    /// this process has exited and opens it. A plain copy left in Downloads goes to the Trash.
    private static func move() throws {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: applicationsFolder).appendingPathComponent("Nimb.app")

        let stage = fm.temporaryDirectory.appendingPathComponent("Nimb-move-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let staged = stage.appendingPathComponent("Nimb.app")
        // Without the extended attributes: a folder synced with iCloud adds some, and they invalidate the signature check.
        // The quarantine flag goes too, since the person has just opened this app on purpose.
        try run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noqtn", source.path, staged.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])

        let script = """
        #!/bin/sh
        PID="$1"; STAGED="$2"; DEST="$3"; ORIGINAL="$4"; STAGE="$5"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$DEST.old"
        rm -rf "$BACKUP"
        [ -e "$DEST" ] && mv "$DEST" "$BACKUP"
        if mv "$STAGED" "$DEST"; then
            rm -rf "$BACKUP"
            case "$ORIGINAL" in
                /Volumes/*|*/AppTranslocation/*) ;;
                *) mv "$ORIGINAL" "$HOME/.Trash/Nimb $(date +%H%M%S).app" 2>/dev/null ;;
            esac
            open "$DEST"
        else
            [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
        fi
        rm -rf "$STAGE"
        """
        let scriptURL = stage.appendingPathComponent("move.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, destination.path, source.path, stage.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> Int32 {
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
        return process.terminationStatus
    }
}
