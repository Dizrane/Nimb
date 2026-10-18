import SwiftUI

@main
struct RDNSApp: App {
    var body: some Scene {
        WindowGroup("Nimb") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
