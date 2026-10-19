import AppKit

/// One Nimb at a time. macOS lets copies of an app from different folders (an old one in Downloads, a new one in
/// Applications) run side by side; two of them would fight over the Telegram proxy port and the DNS settings.
enum SingleInstance {
    /// If another Nimb is already running, brings it to the front and ends this process. The older copy wins.
    static func yieldToRunningCopy() {
        // For testing a second copy next to the first one.
        if ProcessInfo.processInfo.environment["NIMB_ALLOW_MULTIPLE"] != nil { return }
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        let isOlder: (NSRunningApplication) -> Bool = { other in
            if let theirs = other.launchDate, let mine = me.launchDate, theirs != mine { return theirs < mine }
            return other.processIdentifier < me.processIdentifier
        }
        guard let older = others.first(where: isOlder) else { return }
        // Opening the bundle that is already running makes macOS reopen its window if it has been closed.
        if let url = older.bundleURL { NSWorkspace.shared.open(url) } else { older.activate(options: [.activateAllWindows]) }
        exit(0)
    }
}
