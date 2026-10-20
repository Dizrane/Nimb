import SwiftUI

/// Keeps Nimb running in the background when asked to, and brings the window back when the Dock icon is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?
    private static var reallyQuit = false

    /// Set when the program goes on to run (an update, a move to «Программы», the uninstall, which has already turned everything
    /// off): the services are then left as they are.
    private static var keepServices = false

    /// Quits for real, even in background mode: the menu bar item, an update, the uninstall. By default all three services are
    /// turned off first: the program that is gone must not leave DNS, the proxy or the tunnel behind.
    static func quit(stoppingServices: Bool = true) {
        reallyQuit = true
        keepServices = !stoppingServices
        NSApp.terminate(nil)
    }

    /// Brings the main window to the front, or opens it again if it has been closed.
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionMarker.end()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let open = Self.openMainWindow {
            open()
            return false
        }
        return true
    }

    /// In background mode, Command-Q (and Quit in the Dock menu) only hides the window. A shutdown, restart or log out
    /// carries a reason in its Apple event and always goes through.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !Self.reallyQuit && BackgroundMode.shared.enabled && !Self.isSystemQuit {
            sender.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
            return .terminateCancel
        }
        // A full quit, by «Выйти» or by ⌘Q when the person has allowed it: first everything that works is turned off, which may
        // ask for the administrator password. The quit is put off for that time and made again when it is done (waiting inside
        // the first one does not work: the program does not run its own tasks while a quit is pending). A shutdown or a log out
        // must not wait for a password, and the tunnel does not survive a restart anyway.
        if Self.isSystemQuit || Self.keepServices || Self.servicesTurnedOff || !AllServices.shared.anythingWorks { return .terminateNow }
        guard !Self.turningOff else { return .terminateCancel }
        Self.turningOff = true
        Task { @MainActor in
            let left = await AllServices.shared.shutdown()
            Self.turningOff = false
            if left.isEmpty || Self.confirmQuit(leaving: left) {
                Self.servicesTurnedOff = true
                NSApp.terminate(nil)
            } else {
                Self.reallyQuit = false
            }
        }
        return .terminateCancel
    }

    private static var turningOff = false
    private static var servicesTurnedOff = false

    /// Something could not be turned off (the password was refused): the person decides whether to quit anyway.
    private static func confirmQuit(leaving names: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не всё удалось выключить"
        alert.informativeText = "Продолжает работать: \(names.joined(separator: ", ")). Если выйти сейчас, оно останется включённым без Nimb."
        alert.addButton(withTitle: "Остаться")
        alert.addButton(withTitle: "Всё равно выйти")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static var isSystemQuit: Bool {
        let quitReason = AEKeyword(0x7768_793F) // 'why?'
        return NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: quitReason) != nil
    }
}

@main
struct NimbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var telegram = TelegramProxyModel()
    @StateObject private var dns = DNSViewModel()
    @StateObject private var warp = WarpTunnelModel()

    init() {
        AppLog.shared.add("app", "запуск Nimb \(Updater.currentVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        SingleInstance.yieldToRunningCopy()
        SessionMarker.begin()
        Task { @MainActor in
            Notifier.shared.start()
            UpdateViewModel.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup("Nimb", id: "main") {
            ContentView()
                .environmentObject(telegram)
                .environmentObject(dns)
                .environmentObject(warp)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 660)
        .windowResizability(.contentMinSize)

        Window("Что открывает туннель", id: TunnelSitesWindow.windowID) {
            TunnelSitesWindow()
        }
        .windowResizability(.contentSize)
    }
}
