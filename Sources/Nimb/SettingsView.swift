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
            return "Если после замены это сообщение останется, широкий доступ даёт другое правило sudo, не от Nimb."
        }
        if !access.missing.isEmpty {
            return "Для новых подключений (\(access.missing.joined(separator: ", "))) пароль пока запрашивается. «Добавить подключения» включит их в правило (понадобится пароль)."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Настройки", buttonTitle: nil) {}

            // Two columns, so that all the settings are in front of the person at once and nothing is scrolled.
            FitOrScroll {
                HStack(alignment: .top, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.l) {
                    SettingsSection(title: "Работа") {
                        BackgroundCard()
                        LaunchAtLoginCard()
                    }

                    SettingsSection(title: "Помощь") {
                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Первая настройка")
                                    .font(Typo.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Короткое обучение по шагам.")
                                    .font(Typo.small)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Space.s)
                            OutlineButton(title: "Пройти заново", color: Theme.textPrimary) {
                                Navigation.shared.select(.home)
                                onboarding.start()
                            }
                            .disabled(model.isLocked)
                        }
                        .card()
                    }


                    SettingsSection(title: "Удаление") {
                        VStack(alignment: .leading, spacing: Space.s + 2) {
                            Text("Удалить Nimb")
                                .font(Typo.name)
                                .foregroundStyle(Theme.textPrimary)
                            Text("Вернёт DNS к автоматическому и удалит приложение вместе с настройками.")
                                .font(Typo.small)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                OutlineButton(title: "Удалить…", color: Theme.bad, action: model.uninstall)
                                    .disabled(model.isLocked)
                            }
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
                                ? "Старое правило слишком широкое. «Сделать точным» заменит его на безопасное."
                                : model.passwordless
                                ? "DNS переключается без пароля. Только между сервисами Nimb и автоматическим."
                                : "DNS переключается по паролю или Touch ID. Можно разрешить без пароля.",
                            granted: model.passwordless,
                            disabled: model.isLocked,
                            note: accessNote,
                            extraTitle: model.access.needsUpdate ? (model.access.tooBroad ? "Сделать точным" : "Добавить подключения") : nil,
                            extraAction: { model.setPasswordless(true, confirm: false) },
                            action: model.togglePasswordless
                        )
                        PermissionRow(
                            title: "Туннель YouTube и Discord",
                            detail: warp.passwordless
                                ? "Туннель включается и выключается без пароля."
                                : "Туннель включается по паролю или Touch ID. Можно разрешить без пароля.",
                            granted: warp.passwordless,
                            disabled: warp.isWorking || warp.isSettingAccess,
                            action: { warp.setPasswordless(!warp.passwordless) }
                        )
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
