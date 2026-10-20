import Foundation

/// Tells whether the previous run of Nimb ended the usual way. A flag is set at the start and cleared at a real quit; a crash, a
/// force quit or a power cut leaves it set, and the next start knows (the report says so, and so does the diary).
enum SessionMarker {
    private static let key = "sessionOpen"

    /// The previous run did not end through a normal quit.
    private(set) static var previousEndedBadly = false

    static func begin() {
        previousEndedBadly = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        if previousEndedBadly { AppLog.shared.add("app", "прошлый запуск закончился неожиданно (сбой, принудительное закрытие или выключение питания)") }
    }

    static func end() {
        UserDefaults.standard.set(false, forKey: key)
    }
}
