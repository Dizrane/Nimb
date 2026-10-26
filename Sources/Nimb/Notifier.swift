import AppKit
import SwiftUI
import UserNotifications

/// The notification about a new version: when Nimb lives in the menu bar with its window closed, this is the only way for a person to
/// learn that there is an update. One notification for each version, and only while the window is not in front (in front there is the
/// button at the bottom of the window). The permission is asked for in the first set-up and in the settings, never by surprise.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private static let notifiedKey = "notifiedUpdateVersion"
    private static let enabledKey = "updateNotificationsEnabled"

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// Whether the system lets Nimb play a sound. A permission that was given before the sound was asked for does not have it.
    @Published private(set) var soundSetting: UNNotificationSetting = .notSupported
    /// The person's own choice in Nimb (on until they turn it off); the system's permission is a second condition.
    @Published private(set) var enabled: Bool = (UserDefaults.standard.object(forKey: "updateNotificationsEnabled") as? Bool) ?? true

    var isAllowed: Bool { status == .authorized || status == .provisional }
    /// What the switch shows: Nimb is going to tell about updates.
    var isOn: Bool { enabled && isAllowed }

    /// The switch was pressed. Off: no more notifications. On: asks the system if it has not been asked, or shows where to allow it.
    func setOn(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { ask() }
    }

    /// The program may have no bundle (run from the command line): the notification centre does not exist then.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let center else { return }
        center.getNotificationSettings { settings in
            Task { @MainActor in
                let next = settings.authorizationStatus
                if next != self.status { self.status = next }
                if settings.soundSetting != self.soundSetting {
                    self.soundSetting = settings.soundSetting
                    AppLog.shared.add("notifications", "звук уведомлений в системе: \(settings.soundSetting == .enabled ? "включён" : settings.soundSetting == .disabled ? "выключен" : "не предусмотрен")")
                }
            }
        }
    }

    /// The switch was turned on: ask, or, if the person has refused once, show where it is allowed (the system asks only once).
    private func ask() {
        guard let center, !isAllowed else { return }
        if status == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            return
        }
        center.requestAuthorization(options: [.alert]) { granted, error in
            Task { @MainActor in
                self.refresh()
                AppLog.shared.add("notifications", granted ? "уведомления разрешены" : "уведомления не разрешены" + (error.map { " (\($0.localizedDescription))" } ?? ""))
                // A version that came while they were not allowed is told about now.
                if granted, case .available(let release) = UpdateViewModel.shared.state { self.updateAvailable(release.version) }
            }
        }
    }

    /// A newer version has been found. Tells the person once per version.
    func updateAvailable(_ version: String) {
        guard let center, isOn, UpdateNotice.shouldTell(version: version, lastTold: UserDefaults.standard.string(forKey: Self.notifiedKey)) else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedKey)
        let content = UNMutableNotificationContent()
        content.title = "Вышел Nimb \(version)"
        content.body = "Откройте Nimb и нажмите «Обновить до \(version)»."
        post(content, identifier: "nimb-update", failure: "уведомление не показано")
        AppLog.shared.add("notifications", "показал уведомление о версии \(version)")
    }

    /// One identifier for all notifications of a kind: a newer one takes the place of the older one in the Notification Centre, so there is
    /// never a pile. The older one is taken out first: a notification that only replaces another in place comes without banner and sound.
    private func post(_ content: UNNotificationContent, identifier: String, failure: String) {
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        if soundSetting != .disabled && Self.showsBanner(identifier: identifier, appIsActive: NSApp.isActive) { playSound() }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { AppLog.shared.add("notifications", "\(failure): \(error.localizedDescription)") }
        }
    }

    private var sound: NSSound?

    /// Nimb's own sound, the same for everyone: the system one cannot be had by those who gave the permission before it was asked for (the
    /// settings do not even show the line), and its files must be of a few formats. A sound that the person turned off in the settings stays off.
    private func playSound() {
        guard let url = Bundle.main.url(forResource: "notification", withExtension: "mp3"), let next = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep()
            return
        }
        sound = next
        next.play()
    }

    private var dnsTold = false

    /// The network lets no DNS through but its own (see `DNSManager.unreachableWarning`): the person is told once for as long as it lasts, and
    /// again when it comes back after a time of working. Called at every look of the black box with what the page shows.
    func dnsWarning(_ warnings: [String]) {
        let present = warnings.contains { $0.hasPrefix(DNSManager.unreachablePrefix) }
        guard present else { dnsTold = false; return }
        guard !dnsTold, let center, isOn else { return }
        dnsTold = true
        let content = UNMutableNotificationContent()
        content.title = "В этой сети DNS Nimb не отвечает"
        content.body = "Адреса могут не открываться. Откройте Nimb и выключите «Нейросети»."
        post(content, identifier: "nimb-dns", failure: "уведомление о DNS не показано")
        AppLog.shared.add("notifications", "показал уведомление: DNS не отвечает в этой сети")
    }

    /// The button of the test is idle for a moment after a press, so it cannot be pressed in a rush.
    @Published private(set) var testJustSent = false

    /// The person asked to see that notifications work (the button in the settings). A second test takes the place of the first one in the
    /// Notification Centre (the same identifier), so a person who missed the banner can ask again and there is never a pile of them.
    func sendTest() {
        guard let center, isOn, !testJustSent else { return }
        let content = UNMutableNotificationContent()
        content.title = "Проверка уведомлений"
        content.body = "Если вы это видите, Nimb сможет сообщить о новой версии."
        post(content, identifier: Self.testIdentifier, failure: "проверочное уведомление не показано")
        AppLog.shared.add("notifications", "показал проверочное уведомление")
        testJustSent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.testJustSent = false }
    }

    nonisolated static let testIdentifier = "nimb-test"

    /// In front, the window already shows the button: no banner. The test one is the exception: it is asked for in that very window.
    nonisolated static func showsBanner(identifier: String, appIsActive: Bool) -> Bool {
        identifier == testIdentifier || !appIsActive
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let active = await MainActor.run { NSApp.isActive }
        return Self.showsBanner(identifier: notification.request.identifier, appIsActive: active) ? [.banner, .sound] : []
    }

    /// A click on the banner opens the window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppDelegate.showMainWindow() }
    }
}

/// The switch for it, in the first set-up and in the settings.
struct NotificationsCard: View {
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Уведомления об обновлениях")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text(notifier.enabled && notifier.status == .denied
                     ? "Разрешите уведомления для Nimb в «Системных настройках»: Nimb скажет, когда выйдет новая версия."
                     : "Nimb скажет, когда выйдет новая версия.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notifier.isOn {
                    OutlineButton(title: notifier.testJustSent ? "Отправлено" : "Отправить тестовое уведомление", color: Theme.textPrimary) { notifier.sendTest() }
                        .disabled(notifier.testJustSent)
                        .padding(.top, 5)
                        .accessibilityLabel("Отправить тестовое уведомление")
                }
            }
            Spacer(minLength: 8)
            PillSwitch(label: "Уведомления об обновлениях", isOn: notifier.isOn) { notifier.setOn(!notifier.isOn) }
        }
        .card(.neutral)
    }
}
