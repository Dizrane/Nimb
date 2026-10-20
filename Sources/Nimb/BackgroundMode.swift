import SwiftUI

/// "Work in the background": the Nimb icon stays in the menu bar, and closing the window or pressing Command-Q only
/// hides the window, so that the Telegram proxy (and the menu with the DNS switch) keep working.
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Работать в фоне")
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Text("Nimb остаётся в строке меню, когда окно закрыто.")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PillSwitch(label: "Работать в фоне", isOn: background.enabled) { background.enabled.toggle() }
        }
        .card(.neutral)
    }
}
