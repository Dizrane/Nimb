import Foundation

/// One notification for one version, ever: not after a restart, not at the next check, not when the switch is turned off and on, and not
/// for an older version if GitHub answers with a stale page for a moment. A newer version is told about again.
enum UpdateNotice {
    static func shouldTell(version: String, lastTold: String?) -> Bool {
        guard let lastTold else { return true }
        return Updater.isNewer(version, than: lastTold)
    }
}

/// When Nimb asks GitHub about a new version: when it starts, and then every ten minutes for as long as it runs. Never oftener, so that
/// nobody can run into the limit of GitHub (60 requests an hour from one address).
enum UpdateSchedule {
    /// `NIMB_UPDATE_INTERVAL` (seconds) exists for testing only.
    static let interval: TimeInterval = {
        if let text = ProcessInfo.processInfo.environment["NIMB_UPDATE_INTERVAL"], let seconds = TimeInterval(text), seconds >= 5 { return seconds }
        return 10 * 60
    }()

    /// After a check that failed (GitHub did not answer for a minute) the next one comes sooner, so that «не удалось проверить» does not
    /// stay in the bar for ten minutes. A request that GitHub never answered is not counted by its limit.
    static let retryAfterFailure: TimeInterval = min(2 * 60, interval)

    /// How long to wait before the next check.
    static func wait(afterFailure: Bool) -> TimeInterval { afterFailure ? retryAfterFailure : interval }

    /// A few seconds of slack: the timer that asks is not exact, and a check that is due at the 10th minute must not wait for the 11th.
    static func isDue(lastTry: Date, now: Date, interval: TimeInterval = UpdateSchedule.interval) -> Bool {
        now.timeIntervalSince(lastTry) >= interval - min(5, interval / 10)
    }
}
