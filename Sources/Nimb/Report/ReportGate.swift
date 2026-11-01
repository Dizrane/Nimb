import Foundation

/// The latest version that the update check has seen. A report goes only from the latest version: a fault of an older one is mended already
/// (or is about to be), and its reports are noise. The check of updates writes it down each time GitHub answers; between two answers the last
/// word stands, so a program that was told there is a newer version stays quiet until it is updated.
enum ReportFreshness {
    private static let key = "latestKnownVersion"

    static func isOutdated(current: String, latest: String?) -> Bool {
        latest.map { Updater.isNewer($0, than: current) } ?? false
    }

    static func record(latest: String) { UserDefaults.standard.set(latest, forKey: key) }

    /// The newer version that this one has to give way to; nil when this one is the latest (or nothing is known: no answer yet, no net).
    static var newer: String? {
        UserDefaults.standard.string(forKey: key).flatMap { isOutdated(current: Updater.currentVersion, latest: $0) ? $0 : nil }
    }
}

/// Whether a report may go now, and if not, what to say. Two reasons: the build is not ours (`BuildCheck`), or it is not the latest version.
/// Everything that sends (the report of the day, the queue, the window) asks here, and the relay keeps the same rules on its side.
enum ReportGate {
    static func outdatedWords(latest: String?) -> String {
        "Вышла новая версия" + (latest.map { " \($0)" } ?? "") + ", а эта уже не последняя, поэтому тестирование приостановлено. Обновите Nimb: отчёты принимаются только из последней версии."
    }

    /// The words for the person; nil when reports may go.
    static var pausedWords: String? {
        if BuildCheck.problem != nil { return ReportConfig.pausedWords }
        if let latest = ReportFreshness.newer { return outdatedWords(latest: latest) }
        return nil
    }

    /// The same in a few words, for the line of the switch.
    static var shortWords: String? {
        if BuildCheck.problem != nil { return "Тестирование приостановлено: сборка изменена." }
        if ReportFreshness.newer != nil { return "Тестирование приостановлено: есть новая версия." }
        return nil
    }

    static var isOpen: Bool { pausedWords == nil }
}
