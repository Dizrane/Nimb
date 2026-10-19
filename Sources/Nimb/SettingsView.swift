import SwiftUI

/// The settings: what runs by itself, what needs no password, the first set-up again, and the removal.
struct SettingsView: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var onboarding: Onboarding
    @ObservedObject var warp: WarpTunnelModel
    /// The layout of the window the page is shown in: the sidebar layout gives the page a title, the tabs have it on the tab.
    var layout: WindowLayout = .sidebar
    @ObservedObject private var setting = WindowLayoutSetting.shared

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
            if layout == .sidebar { PageHeader(title: "Настройки", buttonTitle: nil) {} }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl - 4) {
                    SettingsSection(title: "Оформление окна") {
                        HStack(alignment: .top, spacing: Space.m) {
                            ForEach(WindowLayout.allCases, id: \.self) { option in
                                LayoutCard(option: option, selected: setting.layout == option) {
                                    withAnimation(.easeInOut(duration: 0.2)) { setting.layout = option }
                                }
                            }
                        }
                    }

                    SettingsSection(title: "Работа") {
                        BackgroundCard()
                        LaunchAtLoginCard()
                    }

                    SettingsSection(title: "Пароль администратора") {
                        PermissionRow(
                            title: "Смена DNS",
                            detail: model.access.tooBroad
                                ? "Старое правило позволяет любой программе поставить любой DNS. «Сделать точным» заменит его на безопасное (один раз нужен пароль)."
                                : model.passwordless
                                ? "DNS переключается без пароля. Разрешено только переключение между сервисами Nimb и автоматическим DNS, чужой адрес задать нельзя. Риск: это может сделать любая программа от вашего имени."
                                : "Сейчас DNS переключается по паролю или Touch ID. Можно разрешить без пароля только переключение между сервисами Nimb и автоматическим DNS.",
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
                                ? "Туннель включается и выключается без пароля. Разрешены только две команды помощника Nimb: включить и выключить. Риск: это может сделать любая программа от вашего имени."
                                : "Сейчас туннель включается по паролю или Touch ID. Можно разрешить без пароля только его включение и выключение. Самая первая установка всё равно спросит пароль один раз.",
                            granted: warp.passwordless,
                            disabled: warp.isWorking || warp.isSettingAccess,
                            action: { warp.setPasswordless(!warp.passwordless) }
                        )
                        Text("Больше Nimb ни о чём не просит: ни доступа к файлам, ни к камере или микрофону.")
                            .font(Typo.small)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                    }

                    SettingsSection(title: "Помощь") {
                        HStack(spacing: Space.m) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Первая настройка")
                                    .font(Typo.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Короткое обучение: по шагам включит нейросети, Telegram, YouTube и Discord.")
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
                            Text("Вернёт DNS к автоматическому, уберёт правила «без пароля» и туннель, закроет приложение и удалит его вместе с настройками и кэшем.")
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
                .padding(.horizontal, Space.page)
                .padding(.top, layout == .sidebar ? Space.s : 16)
                .padding(.bottom, Space.s)
            }
            .scrollIndicators(.hidden)
        }
    }
}
