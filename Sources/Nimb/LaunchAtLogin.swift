import ServiceManagement
import SwiftUI

/// Start Nimb when the person logs in to the Mac: a login item, listed in System Settings → General → Login Items.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published var errorMessage: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func set(_ on: Bool) {
        errorMessage = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }
}

/// The switch for it, in the settings.
struct LaunchAtLoginCard: View {
    @ObservedObject private var launch = LaunchAtLogin.shared
    /// False when it is a row of a card that holds several (see `framedCard`).
    var framed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Запускать при входе в систему")
                        .font(Typo.name)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                PillSwitch(label: "Запускать при входе в систему", isOn: launch.isOn) { launch.set(!launch.isOn) }
            }
            if launch.status == .requiresApproval {
                Text("Подтвердите в «Системных настройках» → «Основные» → «Объекты входа».")
                    .font(Typo.small)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = launch.errorMessage {
                Text(message)
                    .font(Typo.small)
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .framedCard(framed)
        .onAppear { launch.refresh() }
    }
}
