import SwiftUI

@main
struct NimbApp: App {
    @StateObject private var telegram = TelegramProxyModel()

    var body: some Scene {
        WindowGroup("Nimb", id: "main") {
            ContentView()
                .environmentObject(telegram)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
