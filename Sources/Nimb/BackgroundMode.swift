import SwiftUI

/// "Work in the background": the Nimb icon stays in the menu bar when the window is closed.
/// Quit and Command-Q still end the application.
@MainActor
final class BackgroundMode: ObservableObject {
    static let shared = BackgroundMode()
    private static let key = "runInBackground"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.key) }
}

/// The switch for it, shown in the settings and on the Telegram page.
struct BackgroundCard: View {
    @ObservedObject private var background = BackgroundMode.shared
    /// False when it is a row of a card that holds several (see `framedCard`).
    var framed = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Работать в фоне")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 8)
            PillSwitch(label: "Работать в фоне", isOn: background.enabled) { background.enabled.toggle() }
        }
        .framedCard(framed)
    }
}
