import SwiftUI

/// Brings the window back when the Dock icon is clicked (or the app is opened again) after the window was closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let open = Self.openMainWindow {
            open()
            return false
        }
        return true
    }
}

@main
struct NimbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var telegram = TelegramProxyModel()

    init() {
        SingleInstance.yieldToRunningCopy()
    }

    var body: some Scene {
        WindowGroup("Nimb", id: "main") {
            ContentView()
                .environmentObject(telegram)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
