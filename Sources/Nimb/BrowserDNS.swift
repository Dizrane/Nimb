import AppKit
import Foundation

/// Browsers that ask a DNS of their own, over HTTPS, and so never ask the one Nimb has set. Firefox does it by default in Russia and
/// Ukraine since 2022 (https://support.mozilla.org/kb/firefox-dns-over-https); the others only where the person has chosen a provider.
enum BrowserDNS {
    static let firefoxIdentifiers = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]

    static let firefoxText = "Firefox мог включить «DNS через HTTPS» (в России он включён по умолчанию): тогда браузер спрашивает адреса у Cloudflare и обходит Nimb. Выключите его: «Настройки» → «Приватность и защита» → «DNS через HTTPS»."

    /// The line for the person, or nil when there is nothing to say: no Firefox, a Firefox that never started, or one that has
    /// DNS over HTTPS switched off in every profile. `profiles` are the preference files of each profile, as text.
    static func firefoxWarning(installed: Bool, profiles: [String]) -> String? {
        guard installed, !profiles.isEmpty, !profiles.allSatisfy(switchedOff) else { return nil }
        return firefoxText
    }

    /// `user_pref("network.trr.mode", 5);` in the preferences of a profile: 5 is «off» chosen by hand, 0 is «never on». Any other number
    /// (2, 3) means the browser asks Cloudflare. The last line about it wins, as in Firefox.
    static func switchedOff(_ preferences: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"user_pref\(\s*"network\.trr\.mode"\s*,\s*(\d+)\s*\)"#),
              let last = regex.matches(in: preferences, range: NSRange(preferences.startIndex..., in: preferences)).last,
              let digits = Range(last.range(at: 1), in: preferences), let mode = Int(preferences[digits]) else { return false }
        return mode == 5 || mode == 0
    }

    /// What this Mac says: Firefox installed, and the preferences of its profiles.
    static func currentWarning() -> String? {
        let installed = firefoxIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        guard installed else { return nil }
        return firefoxWarning(installed: true, profiles: firefoxProfiles())
    }

    private static func firefoxProfiles() -> [String] {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let profiles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // A folder that cannot be read counts as a profile with nothing set: better a hint too many than none.
        guard !profiles.isEmpty else { return [""] }
        return profiles.map { profile in
            ["prefs.js", "user.js"].compactMap { try? String(contentsOf: profile.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        }
    }
}
