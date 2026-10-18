import SwiftUI

@main
struct NimbApp: App {
    var body: some Scene {
        WindowGroup("Nimb") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
