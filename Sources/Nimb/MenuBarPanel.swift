import SwiftUI

/// The panel that opens from the Nimb icon in the menu bar (320 pt wide): a title with the number of services that work and one
/// big switch for everything; the three services, each with its switch; and «Открыть Nimb…», «Настройки…», «Выйти».
/// Neural networks open a list of the DNS services in the panel itself; Telegram, while the proxy works, has two small buttons.
struct MenuBarPanel: View {
    @ObservedObject var dns: DNSViewModel
    @ObservedObject var telegram: TelegramProxyModel
    let close: () -> Void
    let openWindow: (AppPage?) -> Void

    @ObservedObject private var all = AllServices.shared
    @StateObject private var listOpen = Flag()

    private var count: Int { all.onCount }

    private var title: String {
        if all.allOn { return "Всё включено" }
        return count == 0 ? "Выключено" : "Включено частично"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            VStack(spacing: 2) {
                aiRow
                telegramRow
                if all.warpAvailable { serviceRow(.media) }
            }
            .padding(.vertical, 6)
            separator
            VStack(spacing: 0) {
                footerRow("Открыть Nimb…") { openWindow(nil) }
                footerRow("Настройки…") { openWindow(.settings) }
                footerRow("Выйти") { AppDelegate.quit() }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(count) из \(all.total) работают")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if all.isRunning {
                ProgressView().controlSize(.small)
            } else {
                PillSwitch(isOn: all.allOn, disabled: all.isBusy) { if all.allOn { all.disableAll() } else { all.enableAll() } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var separator: some View { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) }

    private func icon(_ page: AppPage) -> some View {
        Group {
            if let art = page.iconFile(dimmed: !all.isOn(page)) { ArtImage(folder: art.folder, file: art.file, size: 34) }
        }
        .frame(width: 34, height: 34)
    }

    /// A service with a name, a line of state and a switch.
    private func serviceRow(_ page: AppPage, chevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            icon(page)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title).font(Typo.name).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 3) {
                    Text(all.detail(page)).font(Typo.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    if chevron {
                        Image(systemName: listOpen.value ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer(minLength: 8)
            ServiceSwitch(page: page)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var aiRow: some View {
        VStack(spacing: 0) {
            // Clicking the row (not the switch) opens the list of the DNS services.
            serviceRow(.ai, chevron: true)
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { listOpen.value.toggle() } }
            if listOpen.value {
                VStack(spacing: 0) {
                    ForEach(DNSProvider.all) { provider in
                        Button {
                            dns.select(provider)
                            withAnimation(.easeOut(duration: 0.15)) { listOpen.value = false }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .opacity((dns.active ?? dns.selected) == provider ? 1 : 0)
                                    .frame(width: 14)
                                Text(provider.name).font(Typo.small)
                                Spacer(minLength: 8)
                                Text(speed(provider)).font(Typo.mono).foregroundStyle(Theme.textSecondary)
                            }
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(dns.isLocked)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private var telegramRow: some View {
        VStack(spacing: 6) {
            serviceRow(.telegram)
            if telegram.isRunning {
                HStack(spacing: 8) {
                    smallButton("Открыть в Telegram") { telegram.openInTelegram(); close() }
                    smallButton("Скопировать ссылку") { telegram.copyLink() }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 60)
                .padding(.trailing, 16)
                .padding(.bottom, 4)
            }
        }
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    private func footerRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// How fast a DNS service answered at the last check, or a dash if it has not been checked.
    private func speed(_ provider: DNSProvider) -> String {
        guard let seconds = dns.report(for: provider)?.medianSeconds else { return "—" }
        return seconds.formatted(.number.precision(.fractionLength(1))) + " с"
    }
}
