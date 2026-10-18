import SwiftUI

@main
struct RDNSApp: App {
    var body: some Scene {
        WindowGroup("RDNS") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
