import SwiftUI

@MainActor
final class DNSViewModel: ObservableObject {
    @Published var selected: DNSProvider = DNSProvider.all[0]
    @Published var active: DNSProvider? { didSet { updateDockIcon() } }
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var warnings: [String] = []
    @Published var isProbing = false
    @Published var probeProgress = ""
    @Published var probeFraction = 0.0
    @Published var reports: [ProviderReport] = []
    @Published var access = DNSManager.PasswordlessState()
    @Published var isSettingUp = false
    @Published var showSettings = false
    @Published var showTelegram = false

    init() {
        // Read the state synchronously once, so a Mac that already has DNS on opens straight into space.
        let services = DNSManager.physicalServices()
        access = DNSManager.passwordlessState(for: services)
        let current = DNSManager.activeProvider(on: services)
        active = current
        if let current {
            selected = current
            warnings = DNSManager.overrideWarnings(for: current)
        }
        updateDockIcon()
    }

    /// The Dock shows the halo over the planet while DNS is on and the plain halo otherwise.
    /// The icon of the file itself (Finder, Launchpad) stays the plain one; the Dock reverts to it when the app quits.
    private func updateDockIcon() {
        if active != nil, let url = Bundle.main.url(forResource: "AppIconActive", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        } else {
            NSApp.applicationIconImage = nil
        }
    }

    var passwordless: Bool { access.enabled }

    /// True while a DNS change or a service check is running; both need the network undisturbed.
    var isLocked: Bool { isBusy || isProbing || isSettingUp }

    var mode: AppMode {
        if isProbing { return .probing }
        if isBusy || isSettingUp { return .busy }
        return active == nil ? .off : .on
    }

    var best: ProviderReport? {
        reports.reduce(nil) { best, report in
            guard let best else { return report }
            return report.isBetter(than: best) ? report : best
        }
    }

    func report(for provider: DNSProvider) -> ProviderReport? {
        reports.first { $0.provider == provider }
    }

    /// Checks every provider's pool without touching the system DNS.
    func probe() {
        guard !isLocked else { return }
        isProbing = true
        probeProgress = "Определяю адреса…"
        probeFraction = 0
        reports = []
        Task.detached {
            let result = ServiceProbe.run { done, total in
                Task { @MainActor in
                    guard self.isProbing else { return }
                    self.probeProgress = "Проверено \(done) из \(total)"
                    self.probeFraction = total == 0 ? 0 : Double(done) / Double(total)
                }
            }
            await MainActor.run {
                self.reports = result
                self.isProbing = false
                self.probeProgress = ""
            }
        }
    }

    /// Same as tapping the provider: if DNS is on and the best one differs, switches to it.
    func selectBest() {
        if let best { select(best.provider) }
    }

    /// Re-reads the system state off the main thread; skipped while a change is in progress.
    func refresh() {
        guard !isLocked else { return }
        Task.detached {
            let services = DNSManager.physicalServices()
            let active = DNSManager.activeProvider(on: services)
            var warnings: [String] = []
            if let active {
                warnings = DNSManager.overrideWarnings(for: active)
            } else if let partial = DNSManager.partialProvider(on: services) {
                warnings = ["\(partial.provider.name) задан не на всех подключениях (нет на: \(partial.missing.joined(separator: ", "))). Нажмите кнопку, чтобы применить заново."]
                    + DNSManager.overrideWarnings(for: partial.provider)
            }
            let shownWarnings = warnings
            let access = DNSManager.passwordlessState(for: services)
            await MainActor.run {
                guard !self.isLocked else { return }
                self.access = access
                self.active = active
                self.warnings = shownWarnings
                if let active { self.selected = active }
            }
        }
    }

    /// Turns the selected provider on, or resets to automatic DNS if one is already active.
    func toggle() {
        let target: DNSProvider? = active == nil ? selected : nil
        change(to: target)
    }

    /// Picking another provider while one is active switches straight to it.
    func select(_ provider: DNSProvider) {
        selected = provider
        if active != nil, active != provider { change(to: provider) }
    }

    func togglePasswordless() { setPasswordless(!passwordless, confirm: true) }

    /// Installs, renews or removes the sudoers rule that lets DNS change without a password; the risk is explained first.
    func setPasswordless(_ enable: Bool, confirm: Bool) {
        guard !isLocked else { return }
        if enable && confirm {
            let names = DNSManager.physicalServices().filter(DNSManager.isRuleSafe).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Переключать DNS без пароля?"
            alert.informativeText = """
                Nimb добавит правило в \(DNSManager.sudoersPath). Один раз понадобится пароль администратора.

                Правило разрешает вашей учётной записи без пароля только три вещи: переключить DNS на подключениях (\(names)) на один из сервисов Nimb или вернуть автоматический DNS, а также сбросить DNS-кэш. Задать произвольный DNS оно не позволяет. Появится новое подключение: для него пароль будет запрашиваться, пока вы не нажмёте «Добавить подключения» в настройках.

                Риск остаётся: любая программа, запущенная от вашего имени, сможет без пароля переключить DNS между сервисами Nimb (а они видят ваши DNS-запросы) или вернуть автоматический. Ограничить правило именно приложением Nimb система не умеет.

                Забрать разрешение можно в любой момент: правило удаляется целиком.
                """
            alert.addButton(withTitle: "Дать")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isSettingUp = true
        errorMessage = nil
        Task.detached {
            let result = Result { enable ? try DNSManager.enablePasswordless() : try DNSManager.disablePasswordless() }
            let access = DNSManager.passwordlessState(for: DNSManager.physicalServices())
            await MainActor.run {
                self.isSettingUp = false
                self.access = access
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    /// Puts DNS back to automatic, removes the sudoers rule, then quits and deletes the app with its leftovers.
    func uninstall() {
        guard !isLocked else { return }
        if let reason = Uninstaller.blocker() { errorMessage = reason; return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить Nimb?"
        alert.informativeText = """
            Сначала Nimb отключится от DNS-сервисов: DNS вернётся к автоматическому (от роутера или провайдера), а правило «без пароля», если оно включено, будет удалено. Для этого понадобится пароль администратора.

            Затем приложение закроется и удалит само себя вместе с настройками и кэшем. Действие необратимо.
            """
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isSettingUp = true
        errorMessage = nil
        Task.detached {
            let services = DNSManager.servicesUsingProviders()
            let removeRule = DNSManager.passwordlessState(for: DNSManager.physicalServices()).enabled
            var failure: Error?
            do {
                if !services.isEmpty || removeRule { try DNSManager.resetBeforeUninstall(services, removingRule: removeRule) }
                try Uninstaller.scheduleRemoval()
            } catch {
                failure = error
            }
            let outcome = failure
            await MainActor.run {
                self.isSettingUp = false
                if let outcome {
                    if case DNSError.cancelled = outcome {} else { self.errorMessage = outcome.localizedDescription }
                    self.refresh()
                } else {
                    AppDelegate.quit()
                }
            }
        }
    }

    private func change(to provider: DNSProvider?) {
        guard !isLocked else { return }
        isBusy = true
        errorMessage = nil
        Task.detached {
            let services = DNSManager.physicalServices()
            let result = Result { try DNSManager.apply(provider, to: services) }
            await MainActor.run {
                self.isBusy = false
                if case .failure(let error) = result {
                    if case DNSError.cancelled = error {} else { self.errorMessage = error.localizedDescription }
                }
                self.refresh()
            }
        }
    }
}

@MainActor
final class UpdateViewModel: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published var state: State = .idle

    /// Whether the app asks GitHub for a newer version once at launch. The button in the footer always works.
    @Published var checkOnLaunch = UserDefaults.standard.object(forKey: "checkUpdatesOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkOnLaunch, forKey: "checkUpdatesOnLaunch") }
    }

    /// A silent check stays quiet when offline or when GitHub cannot be reached.
    func check(silent: Bool) {
        if case .installing = state { return }
        if case .checking = state { return }
        state = .checking
        Task {
            let started = Date()
            let outcome: State
            do {
                let release = try await Updater.latestRelease()
                outcome = Updater.isNewer(release.version, than: Updater.currentVersion) ? .available(release) : .upToDate
            } catch {
                outcome = silent ? .idle : .failed("Не удалось проверить обновления: \(error.localizedDescription)")
            }
            // A quick answer would make the icon flicker instead of turning; let it turn for a moment.
            if !silent {
                let remaining = 0.9 - Date().timeIntervalSince(started)
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            state = outcome
        }
    }

    func install(_ release: Release) {
        state = .installing("Загрузка…")
        Task {
            do {
                try await Updater.install(release) { text in
                    Task { @MainActor in self.state = .installing(text) }
                }
                AppDelegate.quit()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject private var model: DNSViewModel
    @StateObject private var updates = UpdateViewModel()
    @EnvironmentObject private var telegram: TelegramProxyModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if model.showSettings {
                SettingsView(model: model, updates: updates)
                    .transition(.opacity)
            } else if model.showTelegram {
                TelegramPage(telegram: telegram) { withAnimation(.easeInOut(duration: 0.3)) { model.showTelegram = false } }
                    .transition(.opacity)
            } else {
                Hero(model: model)
                ScrollView {
                    ProvidersSection(model: model)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
            FooterBar(updates: updates, canInstall: !model.isLocked)
        }
        .frame(width: 400, height: 720)
        .overlay(alignment: .topTrailing) {
            if !model.showSettings && !model.showTelegram {
                HStack(spacing: 0) {
                    Button { withAnimation(.easeInOut(duration: 0.3)) { model.showTelegram = true } } label: {
                        Image(systemName: "paperplane")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(telegram.isRunning ? Theme.ok : Theme.textSecondary)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Прокси для Telegram")
                    .accessibilityLabel("Прокси для Telegram")

                    Button { withAnimation(.easeInOut(duration: 0.3)) { model.showSettings = true } } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Настройки")
                    .accessibilityLabel("Настройки")
                }
                .padding(.top, 6)
                .padding(.trailing, 10)
            }
        }
        // The hidden title bar adds its height (28 pt) to the window on top of the content, which would leave a black
        // strip under the footer; the content reports itself that much shorter so that the window fits it exactly.
        .padding(.bottom, -28)
        // As a background the scenery cannot widen the layout; it is larger than the window.
        .background(alignment: .top) {
            // The layout is reported 28 pt shorter than the window (see above); the scenery is drawn at the full height
            // so that nothing, including the footer, is left standing on bare window background.
            NimbBackground(lit: model.active != nil).frame(width: 400, height: 720)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowConfigurator())
        .animation(.easeInOut(duration: 0.5), value: model.reports.count)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onAppear {
            if updates.checkOnLaunch { updates.check(silent: true) }
            telegram.openMainWindow = { openWindow(id: "main") }
            StatusMenuController.shared.configure(dns: model, telegram: telegram)
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            // After the window is up, so that the question has something behind it.
            DispatchQueue.main.async { MoveToApplications.offer() }
        }
    }
}

// MARK: - Hero

private struct Hero: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 6) {
            HeroButton(mode: model.mode, lit: model.active != nil, region: model.active?.region ?? model.selected.region, action: model.toggle)
                .disabled(model.isLocked)
                .padding(.vertical, -22)
                .accessibilityLabel(model.active == nil ? "Включить Smart DNS" : "Выключить Smart DNS")

            Text(title)
                .font(Typo.status)
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                .contentTransition(.opacity)

            VStack(spacing: 4) {
                if let active = model.active, !model.isLocked {
                    HStack(spacing: 7) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text(active.name)
                            .font(Typo.name)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(active.addresses.joined(separator: "   "))
                        .font(Typo.mono)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(subtitle)
                        .font(Typo.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 38, alignment: .top)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.45), value: model.mode)
    }

    private var title: String {
        switch model.mode {
        case .off: return "Выключено"
        case .on: return "Включено"
        case .probing: return "Проверка сервисов"
        case .busy: return model.isSettingUp ? "Настраиваю доступ" : "Применяю DNS"
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .off: return "Используется DNS роутера или провайдера"
        case .on: return ""
        case .probing: return "Спрашиваю DNS и запрашиваю сайты и API"
        case .busy: return model.passwordless && model.access.missing.isEmpty && !model.isSettingUp ? "Меняю DNS на всех подключениях" : "Подтвердите пароль администратора"
        }
    }
}

// MARK: - Providers

private struct ProvidersSection: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("DNS-провайдеры")
                    .sectionLabel()
                Spacer()
                ProbeButton(model: model)
            }
            .padding(.horizontal, 2)

            if let best = model.best, best.workingCount > 0 {
                BestBanner(report: best, isSelected: model.selected == best.provider, locked: model.isLocked, action: model.selectBest)
                    .transition(.opacity)
            }

            ForEach(DNSProvider.all) { provider in
                ProviderCard(
                    provider: provider,
                    report: model.report(for: provider),
                    isSelected: model.selected == provider,
                    isActive: model.active == provider,
                    isBest: model.best?.provider == provider && (model.best?.workingCount ?? 0) > 0,
                    locked: model.isLocked
                ) {
                    model.select(provider)
                }
            }

            if !model.warnings.isEmpty {
                NoticeCard(lines: model.warnings, color: Theme.warn, symbol: "exclamationmark.triangle")
            }
            if let message = model.errorMessage {
                NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
            }
        }
    }
}

/// A permission Nimb can hold: what it is for, what it costs, and a button to give or take it back.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let disabled: Bool
    var note: String? = nil
    var extraTitle: String? = nil
    var extraAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(granted ? Theme.warn : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                Text(title)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(granted ? "Разрешено" : "Не разрешено")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(detail)
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(Typo.small)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if let extraTitle, let extraAction {
                    OutlineButton(title: extraTitle, color: Theme.textPrimary, action: extraAction)
                        .disabled(disabled)
                }
                OutlineButton(title: granted ? "Забрать" : "Дать", color: granted ? Theme.warn : Theme.textPrimary, action: action)
                    .disabled(disabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .white, tintOpacity: 0.02, borderOpacity: 0.16, radius: 10)
    }
}

struct OutlineButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(color.opacity(0.55), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: DNSViewModel
    @ObservedObject var updates: UpdateViewModel

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
            HStack {
                Text("Настройки")
                    .font(Typo.status)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.3)) { model.showSettings = false } } label: {
                    Text("Готово")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 10) {
                    BackgroundCard()

                    HStack { Text("Разрешения").sectionLabel(); Spacer() }
                        .padding(.horizontal, 2)

                    PermissionRow(
                        title: "Смена DNS без пароля",
                        detail: model.access.tooBroad
                            ? "Сейчас у вас старое правило: оно позволяет любой программе от вашего имени поставить любой DNS. Нажмите «Сделать точным»: правило заменится на безопасное, один раз понадобится пароль."
                            : model.passwordless
                            ? "DNS меняется без пароля. Правило sudo (\(DNSManager.sudoersPath)) разрешает только переключение между сервисами Nimb и автоматическим DNS и сброс кэша: произвольный DNS задать нельзя. Цена: любая программа от вашего имени может это же сделать."
                            : "Сейчас macOS просит пароль администратора или Touch ID при каждом переключении. Можно разрешить без пароля только переключение между сервисами Nimb и автоматическим DNS (правило sudo из трёх видов команд, без подстановок).",
                        granted: model.passwordless,
                        disabled: model.isLocked,
                        note: accessNote,
                        extraTitle: model.access.needsUpdate ? (model.access.tooBroad ? "Сделать точным" : "Добавить подключения") : nil,
                        extraAction: { model.setPasswordless(true, confirm: false) },
                        action: model.togglePasswordless
                    )

                    PermissionRow(
                        title: "Обновления при запуске",
                        detail: "Один запрос к GitHub при запуске, чтобы узнать о новой версии. Кнопка проверки внизу окна работает в любом случае.",
                        granted: updates.checkOnLaunch,
                        disabled: false,
                        action: { updates.checkOnLaunch.toggle() }
                    )

                    Text("Больше Nimb ни о чём не просит: ни доступа к файлам, ни к камере или микрофону.")
                        .font(Typo.small)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)

                    HStack { Text("Удаление").sectionLabel(); Spacer() }
                        .padding(.horizontal, 2)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Удалить Nimb")
                            .font(Typo.name)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Вернёт DNS к автоматическому, уберёт правило «без пароля», закроет приложение и удалит его вместе с настройками и кэшем.")
                            .font(Typo.small)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            OutlineButton(title: "Удалить…", color: Theme.bad, action: model.uninstall)
                                .disabled(model.isLocked)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(tint: Theme.bad, tintOpacity: 0.03, borderOpacity: 0.28, radius: 10)

                    if model.isSettingUp {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Подтвердите пароль администратора…")
                                .font(Typo.small)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let message = model.errorMessage {
                        NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ProbeButton: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        Button(action: model.probe) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: geo.size.width * model.probeFraction)
                        .animation(.easeOut(duration: 0.25), value: model.probeFraction)
                }
                .opacity(model.isProbing ? 1 : 0)

                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .regular))
                    Text(model.isProbing ? model.probeProgress : "Проверить сервисы")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
            }
            .frame(width: 184, height: 28)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .disabled(model.isLocked)
        .opacity(model.isLocked && !model.isProbing ? 0.5 : 1)
    }
}

private struct ProviderCard: View {
    let provider: DNSProvider
    let report: ProviderReport?
    let isSelected: Bool
    let isActive: Bool
    let isBest: Bool
    let locked: Bool
    let onSelect: () -> Void

    @StateObject private var hover = Flag()
    @StateObject private var details = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(provider.name)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if isBest {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Theme.warn)
                        .help("Лучший по итогам проверки")
                }
                if isActive { Badge(text: "Активен", color: Theme.ok) }
                Spacer(minLength: 4)
                if let report {
                    SpeedBadge(seconds: report.medianSeconds)
                    Button { details.value.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Подробности проверки")
                    .popover(isPresented: $details.value, arrowEdge: .trailing) { DetailsView(report: report) }
                }
                RadioMark(selected: isSelected)
            }

            Text(provider.addresses.joined(separator: "   "))
                .font(Typo.mono)
                .foregroundStyle(Theme.textSecondary)

            if let report {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ForEach(report.services) { ServicePill(result: $0) }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(report.services) { ServicePill(result: $0) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tintOpacity: isSelected ? 0.04 : 0, borderOpacity: isSelected ? 0.5 : hover.value ? 0.24 : 0.11)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hover.value = $0 }
        .allowsHitTesting(!locked)
        .opacity(locked ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.3), value: hover.value)
        .animation(.easeInOut(duration: 0.3), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A hairline circle, filled with a small dot when chosen.
private struct RadioMark: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0.28), lineWidth: 1)
            Circle().fill(Color.white.opacity(0.95)).frame(width: 8, height: 8).opacity(selected ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.3), value: selected)
    }
}

/// Small tracked caps in a hairline box instead of a filled pill.
private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

/// Three thin bars that fill up with speed, plus the time to the first byte.
private struct SpeedBadge: View {
    let seconds: Double?

    private var level: Int {
        guard let seconds else { return 0 }
        return seconds < 0.6 ? 3 : seconds < 1.2 ? 2 : 1
    }

    private var color: Color { level == 3 ? Theme.ok : level == 2 ? Theme.warn : Theme.bad }

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(i < level ? color : Color.white.opacity(0.16))
                        .frame(width: 2.5, height: 5 + CGFloat(i) * 3.5)
                }
            }
            .frame(height: 12)
            Text(seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) с" } ?? "—")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seconds.map { "Скорость \($0.formatted(.number.precision(.fractionLength(1)))) секунды" } ?? "Нет ответа")
    }
}

/// One service with a bare tick, exclamation mark or cross, in a hairline box.
private struct ServicePill: View {
    let result: ServiceResult

    private var style: (symbol: String, color: Color) {
        switch result.status {
        case .works: return ("checkmark", Theme.ok)
        case .unstable: return ("exclamationmark.triangle", Theme.warn)
        case .down: return ("xmark", Theme.bad)
        case .blocked: return ("nosign", Theme.bad)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: style.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(style.color)
            Text(result.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(style.color.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.name): \(result.status == .works ? "работает" : result.status == .unstable ? "нестабильно" : result.status == .blocked ? "закрыт" : "не отвечает")")
    }
}

private struct DetailsView: View {
    let report: ProviderReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.provider.name).font(Typo.name)
            ForEach(ProbeTarget.services, id: \.self) { service in
                HStack {
                    Text(service).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 16)
                    Text("сайт \(count(service, .site)) · API \(count(service, .api))")
                        .font(Typo.mono)
                        .foregroundStyle(.secondary)
                }
            }
            if !report.refusals.isEmpty {
                Divider()
                ForEach(report.refusals, id: \.self) { line in
                    Label(line, systemImage: "nosign")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.deadAddresses.isEmpty {
                Divider()
                Label("Без нормального ответа: \(report.deadAddresses.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warn)
            }
            Divider()
            Text("Цифры — сколько адресов пула ответило как положено. Отказ из-за региона, страница ограничений и ответ 403 не считаются. Сервис работает, если ответило не менее 75%. Проверка не гарантирует, что откроются приложения.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 290)
    }

    private func count(_ service: String, _ kind: ProbeTarget.Kind) -> String {
        let samples = report.samples.filter { $0.target.service == service && $0.target.kind == kind }
        return "\(samples.filter(\.ok).count)/\(samples.count)"
    }
}

private struct BestBanner: View {
    let report: ProviderReport
    let isSelected: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Рекомендуем")
                    .sectionLabel()
                    .foregroundStyle(Theme.warn)
                Text(report.provider.name)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Работает \(report.workingCount) из \(ProbeTarget.services.count) сервисов")
                    .font(Typo.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if isSelected {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    Text("Выбран").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.ok)
            } else {
                Button(action: action) {
                    Text("Выбрать")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warn.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(locked)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCard(tint: Theme.warn, tintOpacity: 0.04, borderOpacity: 0.32)
    }
}

struct NoticeCard: View {
    let lines: [String]
    let color: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(Typo.small)
                        .foregroundStyle(Color.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: color, tintOpacity: 0.04, borderOpacity: 0.3, radius: 10)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var updates: UpdateViewModel
    let canInstall: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ChannelLink()
                    .padding(.leading, -6)
                    .padding(.trailing, -7)
                Text("Nimb \(Updater.currentVersion)")
                    .font(Typo.mono)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                switch updates.state {
                case .installing(let text):
                    ProgressView().controlSize(.small)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                case .available(let release):
                    Button { updates.install(release) } label: {
                        Label("Обновить до \(release.version)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ok))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!canInstall)
                case .idle, .failed, .checking, .upToDate:
                    CheckUpdatesButton(updates: updates)
                }
            }
            if case .failed(let message) = updates.state {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

/// A small round Telegram logo that opens the project's channel, @NimbProject.
private struct ChannelLink: View {
    private static let url = URL(string: "https://t.me/NimbProject")!

    var body: some View {
        Button { NSWorkspace.shared.open(Self.url) } label: {
            Group {
                if let url = Bundle.main.url(forResource: "telegram", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 14, height: 14).opacity(0.75)
                } else {
                    Image(systemName: "paperplane").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Новости и релизы Nimb в Telegram: @NimbProject")
        .accessibilityLabel("Telegram-канал Nimb Project")
    }
}

/// The status of the version with an update icon. Pressing it checks GitHub: the icon turns while it asks and the
/// text changes if a new version has come out.
private struct CheckUpdatesButton: View {
    @ObservedObject var updates: UpdateViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var checking: Bool {
        if case .checking = updates.state { return true }
        return false
    }

    private var text: String {
        switch updates.state {
        case .checking: return "Проверяю…"
        case .upToDate: return "Актуальная версия"
        default: return "Проверить обновления"
        }
    }

    var body: some View {
        Button { updates.check(silent: false) } label: {
            HStack(spacing: 6) {
                TimelineView(.animation(paused: !checking || reduceMotion)) { context in
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(checking && !reduceMotion ? context.date.timeIntervalSinceReferenceDate * 360 : 0))
                }
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(checking)
        .help("Проверить, вышла ли новая версия")
        .accessibilityLabel(text)
    }
}
