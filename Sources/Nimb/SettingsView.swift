import SwiftUI

/// The settings: what runs by itself, what needs no password, the first set-up again, and the removal.
struct SettingsView: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var onboarding: Onboarding
    @ObservedObject var warp: WarpTunnelModel

    private var accessNote: String? {
        let access = model.access
        guard access.enabled else { return nil }
        if access.tooBroad {
            return "Если сообщение осталось, широкий доступ даёт другое правило sudo."
        }
        if !access.missing.isEmpty {
            return "Для новых подключений (\(access.missing.joined(separator: ", "))) нужен пароль. «Добавить подключения» включит их в правило."
        }
        if access.providersMissing {
            return "Для новых сервисов (например MagicDNS) нужен пароль. «Обновить правило» добавит их."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Настройки", buttonTitle: nil) {}

            // Two columns, so that all the settings are in front of the person at once and nothing is scrolled. They stand under the title,
            // as on Windows.
            FitOrScroll(alignment: .top) {
                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.l) {
                    SettingsSection(title: "Работа") {
                        BackgroundCard()
                        LaunchAtLoginCard()
                        NotificationsCard()
                    }

                    SettingsSection(title: "Помощь") {
                        VStack(alignment: .leading, spacing: Space.m) {
                            HStack(spacing: Space.m) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Сообщить о проблеме")
                                        .font(Typo.name)
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("Без паролей и личных данных.")
                                        .font(Typo.small)
                                        .foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: Space.s)
                                OutlineButton(title: "Отправить…", color: Theme.textPrimary) { ReportCenter.shared.isShown = true }
                                    .accessibilityLabel("Сообщить о проблеме")
                            }
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            HelpTestingRow()
                        }
                        .card()

                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Первая настройка")
                                    .font(Typo.name)
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer(minLength: Space.s)
                            OutlineButton(title: "Пройти заново", color: Theme.textPrimary) {
                                Navigation.shared.select(.home)
                                onboarding.start()
                            }
                            .disabled(model.isLocked)
                            .accessibilityLabel("Пройти первую настройку заново")
                        }
                        .card()
                    }


                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(alignment: .leading, spacing: Space.l) {
                    SettingsSection(title: "Пароль администратора") {
                        PermissionRow(
                            title: "Смена DNS",
                            detail: model.access.tooBroad
                                ? "Правило слишком широкое. «Сделать точным» заменит его."
                                : "Только между сервисами Nimb и автоматическим DNS.",
                            granted: model.passwordless,
                            disabled: model.isLocked,
                            note: accessNote,
                            extraTitle: model.access.needsUpdate ? (model.access.tooBroad ? "Сделать точным" : model.access.missing.isEmpty ? "Обновить правило" : "Добавить подключения") : nil,
                            extraAction: { model.setPasswordless(true, confirm: false) },
                            action: model.togglePasswordless
                        )
                        PermissionRow(
                            title: "Туннель YouTube и Discord",
                            detail: warp.passwordless && warp.unsafeFolder != nil
                                ? "Небезопасно: папка «\(warp.unsafeFolder ?? "")» доступна не только администратору. Заберите разрешение."
                                : "",
                            granted: warp.passwordless,
                            disabled: warp.isWorking || warp.isSettingAccess,
                            action: { warp.setPasswordless(!warp.passwordless) }
                        )
                    }

                    SettingsSection(title: "Удаление") {
                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Удалить Nimb")
                                    .font(Typo.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Вернёт DNS и удалит приложение с настройками.")
                                    .font(Typo.small)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Space.s)
                            OutlineButton(title: "Удалить…", color: Theme.bad, action: model.uninstall)
                                .disabled(model.isLocked)
                                .accessibilityLabel("Удалить Nimb")
                        }
                        .card()
                    }

                    if model.isSettingUp {
                        HStack(spacing: Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Подтвердите пароль администратора…")
                                .font(Typo.small)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let message = model.errorMessage ?? warp.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.s)
                .padding(.bottom, Space.s)
            }
        }
    }
}
