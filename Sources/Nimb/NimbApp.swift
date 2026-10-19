import SwiftUI

/// Keeps Nimb running in the background when asked to, and brings the window back when the Dock icon is clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?
    private static var reallyQuit = false

    /// Quits for real, even in background mode: the menu bar item, an update, the uninstall.
    static func quit() {
        reallyQuit = true
        NSApp.terminate(nil)
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
        if Self.reallyQuit || !BackgroundMode.shared.enabled || Self.isSystemQuit { return .terminateNow }
        sender.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
        return .terminateCancel
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
        SingleInstance.yieldToRunningCopy()
    }

    var body: some Scene {
        WindowGroup("Nimb", id: "main") {
            ContentView()
                .environmentObject(telegram)
                .environmentObject(dns)
                .environmentObject(warp)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentMinSize)
    }
}
