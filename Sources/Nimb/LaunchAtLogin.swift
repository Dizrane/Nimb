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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Запускать при входе в систему")
                        .font(Typo.name)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Nimb откроется сам, когда вы войдёте в систему. Вместе с работой в фоне всё включится без вас.")
                        .font(Typo.small)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Запускать при входе в систему", isOn: Binding(get: { launch.isOn }, set: { launch.set($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                .tint(Theme.ok)
            }
            if launch.status == .requiresApproval {
                Text("macOS ждёт подтверждения: «Системные настройки» → «Основные» → «Объекты входа» → включите Nimb.")
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
        .card(.neutral)
        .onAppear { launch.refresh() }
    }
}
