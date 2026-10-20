import SwiftUI

@MainActor
final class DNSViewModel: ObservableObject {
    @Published var selected: DNSProvider = DNSProvider.all[0]
    @Published var active: DNSProvider? { didSet { updateDockIcon(); if active != oldValue { AppLog.shared.add("dns", "DNS: \(active?.name ?? "выключен")") } } }
    @Published var isBusy = false
    @Published var errorMessage: String? { didSet { if let message = errorMessage { AppLog.shared.add("dns", "ошибка: \(message)") } } }
    @Published var warnings: [String] = []
    @Published var isProbing = false
    @Published var probeProgress = ""
    @Published var probeFraction = 0.0
    @Published var reports: [ProviderReport] = []
    @Published var access = DNSManager.PasswordlessState()
    @Published var isSettingUp = false

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

    /// Checks every provider's pool without touching the system DNS. `then` runs when the answers are in.
    func probe(then completion: (() -> Void)? = nil) {
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
                completion?()
            }
        }
    }

    /// The one-button set-up of the first launch: checks every service, takes the best one and switches to it.
    func enableBest() {
        probe { [self] in
            if let best, best.workingCount > 0 { selected = best.provider }
            if active != selected { change(to: selected) }
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
                // Only what changed is published: the same value set again would redraw the pages and the menu for nothing.
                if self.access != access { self.access = access }
                if self.active != active { self.active = active }
                if self.warnings != shownWarnings { self.warnings = shownWarnings }
                if let active, self.selected != active { self.selected = active }
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
            Сначала Nimb отключится от DNS-сервисов: DNS вернётся к автоматическому (от роутера или провайдера), а правило «без пароля» и туннель WARP, если они включены, будут удалены. Для этого понадобится пароль администратора.

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
            let removeTunnel = WarpPaths.isInstalled
            var failure: Error?
            do {
                if !services.isEmpty || removeRule || removeTunnel {
                    try DNSManager.resetBeforeUninstall(services, removingRule: removeRule, removingTunnel: removeTunnel)
                }
                // The entry in «Объекты входа» goes away with the app, not later by itself.
                await MainActor.run { LaunchAtLogin.shared.set(false) }
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
                    AppDelegate.quit(stoppingServices: false)
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
                // `apply` has read the servers back and checked them, so success means the state is the one asked for. It
                // is set in the same moment as "not busy": a reading that came later left a gap in which the page, the
                // menu and "turn everything off" still saw the old state.
                if case .success = result {
                    if self.active != provider { self.active = provider }
                    if let provider, self.selected != provider { self.selected = provider }
                }
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
    /// When GitHub last answered, and whether the last try failed (a failed try is not shown as an error: it is quiet).
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastCheckFailed = false

    /// One for the whole program, not for the window: the checks go on while Nimb lives in the menu bar with its window closed.
    static let shared = UpdateViewModel()

    private var lastTry = Date.distantPast
    private var timer: Timer?

    /// Called once when the program starts: a check now, then one every `UpdateSchedule.interval` for as long as the program runs,
    /// whether or not its window is open or in front, and one at once when it comes to the front after a long time.
    func start() {
        guard timer == nil else { return }
        checkIfDue()
        let tick = min(60, max(1, UpdateSchedule.interval / 4))
        let created = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        created.tolerance = tick / 6
        timer = created
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func checkIfDue() {
        guard UpdateSchedule.isDue(lastTry: lastTry, now: Date()) else { return }
        check()
    }

    private func check() {
        if case .installing = state { return }
        if case .checking = state { return }
        let before = state
        lastTry = Date()
        state = .checking
        AppLog.shared.add("update", "проверяю обновления")
        Task {
            do {
                let release = try await Updater.latestRelease()
                lastChecked = Date()
                lastCheckFailed = false
                let newer = Updater.isNewer(release.version, than: Updater.currentVersion)
                AppLog.shared.add("update", newer ? "есть новая версия \(release.version)" : "версия \(Updater.currentVersion) актуальна")
                state = newer ? .available(release) : .upToDate
                if newer { Notifier.shared.updateAvailable(release.version) }
            } catch {
                AppLog.shared.add("update", "проверка обновлений не удалась: \(error.localizedDescription)")
                lastCheckFailed = true
                if case .available = before { state = before } else { state = .idle }
            }
        }
    }

    func install(_ release: Release) {
        state = .installing("Загрузка…")
        Task {
            do {
                try await Updater.install(release) { text in
                    Task { @MainActor in self.state = .installing(text) }
                }
                AppDelegate.quit(stoppingServices: false)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject private var model: DNSViewModel
    @ObservedObject private var updates = UpdateViewModel.shared
    @ObservedObject private var onboarding = Onboarding.shared
    @ObservedObject private var all = AllServices.shared
    @ObservedObject private var report = ReportCenter.shared
    @ObservedObject private var nav = Navigation.shared
    @EnvironmentObject private var telegram: TelegramProxyModel
    @EnvironmentObject private var warp: WarpTunnelModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if onboarding.isShown {
                    // The first set-up stays a column of 460 pt in the middle of the window.
                    OnboardingView(model: model, telegram: telegram, warp: warp, onboarding: onboarding)
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 0) {
                        SidebarView()
                        PageHost(page: nav.page)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FooterBar(updates: updates, canInstall: !model.isLocked)
        }
        .frame(minWidth: WindowConfigurator.minimumSize.width, maxWidth: .infinity, minHeight: WindowConfigurator.minimumSize.height, maxHeight: .infinity)
        .background { NimbBackground(lit: all.effectiveCount > 0) }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowConfigurator())
        // The one key of the keyboard that Nimb answers: Escape goes back to «Главная».
        .background {
            Button("") { if !onboarding.isShown && nav.page != .home { nav.select(.home) } }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $report.isShown) { ReportSheet() }
        .animation(.easeInOut(duration: 0.5), value: model.reports.count)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isShown)
        .animation(.easeOut(duration: 0.15), value: nav.page)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
            warp.refreshAccess()
        }
        .onAppear {
            telegram.openMainWindow = { openWindow(id: "main") }
            StatusMenuController.shared.configure(dns: model, telegram: telegram, warp: warp)
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            // After the window is up, so that the question has something behind it.
            DispatchQueue.main.async {
                MoveToApplications.offer()
                onboarding.showIfFresh(existingSetup: model.active != nil || WarpPaths.isInstalled || UserDefaults.standard.object(forKey: "telegramProxyPort") != nil)
            }
        }
    }
}

// MARK: - Hero

struct DNSHero: View {
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
        case .off: return "Включите, чтобы открывались ChatGPT, Claude, Gemini и другие нейросети"
        case .on: return ""
        case .probing: return "Спрашиваю DNS и запрашиваю сайты и API"
        case .busy: return model.passwordless && model.access.missing.isEmpty && !model.isSettingUp ? "Меняю DNS на всех подключениях" : "Подтвердите пароль администратора"
        }
    }
}

// MARK: - Providers

struct ProvidersSection: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: Space.gap) {
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

            // One slim row for each service; two by two once the check has results (they make the cards taller).
            LazyVGrid(columns: model.reports.isEmpty
                        ? [GridItem(.flexible(), alignment: .top)]
                        : [GridItem(.flexible(), spacing: Space.gap, alignment: .top), GridItem(.flexible(), spacing: Space.gap, alignment: .top)],
                      spacing: Space.gap) {
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

struct OutlineButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(hover.value ? 0.16 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(color.opacity(hover.value ? 0.75 : 0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover.value = $0 && isEnabled }
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: hover.value)
    }
}

private struct ProbeButton: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        Button { model.probe() } label: {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: geo.size.width * model.probeFraction)
                        .animation(.easeOut(duration: 0.25), value: model.probeFraction)
                }
                .opacity(model.isProbing ? 1 : 0)

                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg").accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(provider.name)
                    .font(Typo.name)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if isBest {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(Theme.warn)
                        .help("Лучший по итогам проверки")
                }
                if isActive {
                    Text("· активен")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ok)
                        .lineLimit(1)
                }
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

            if let report {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ForEach(report.services) { ServicePill(result: $0) }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                        ForEach(report.services) { ServicePill(result: $0) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tintOpacity: isSelected ? 0.04 : 0, borderOpacity: isSelected ? 0.5 : hover.value ? 0.24 : 0.11)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hover.value = $0 }
        .allowsHitTesting(!locked)
        .opacity(locked ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.3), value: hover.value)
        .animation(.easeInOut(duration: 0.3), value: isSelected)
        // One element that VoiceOver can read and press: a tap gesture alone is not an action for it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.name)
        .accessibilityValue(spokenState)
        .accessibilityHint(locked ? "" : "Переключить DNS на этот сервис")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: "Подробности проверки") { if report != nil { details.value.toggle() } }
    }

    /// What the card says, in words: active, chosen, the best, how many services work and how fast.
    private var spokenState: String {
        var parts: [String] = []
        if isActive { parts.append("активен") }
        if isSelected && !isActive { parts.append("выбран") }
        if isBest { parts.append("лучший по итогам проверки") }
        if let report {
            parts.append("работает \(report.workingCount) из \(report.services.count) сервисов")
            if let seconds = report.medianSeconds { parts.append("ответ \(seconds.formatted(.number.precision(.fractionLength(1)))) секунды") }
        }
        return parts.joined(separator: ", ")
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
            Image(systemName: style.symbol).accessibilityHidden(true)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(style.color)
            Text(result.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Рекомендуем")
                    .sectionLabel()
                    .foregroundStyle(Theme.warn)
                HStack(spacing: 8) {
                    Text(report.provider.name)
                        .font(Typo.name)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("работает \(report.workingCount) из \(ProbeTarget.services.count)")
                        .font(Typo.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isSelected {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").accessibilityHidden(true).font(.system(size: 10, weight: .semibold))
                    Text("Выбран").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.ok)
            } else {
                Button(action: action) {
                    Text("Выбрать")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.warn)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warn.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(locked)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(tint: Theme.warn, tintOpacity: 0.04, borderOpacity: 0.32, radius: 14)
    }
}

struct NoticeCard: View {
    let lines: [String]
    let color: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).accessibilityHidden(true)
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
        .card(tint: color)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var updates: UpdateViewModel
    let canInstall: Bool

    private static let channel = URL(string: "https://t.me/NimbProject")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                versionLine
                    .padding(.leading, 20)
                Spacer(minLength: 8)
                // The whole right half of the bar is the button: a small icon is hard to hit.
                Button { NSWorkspace.shared.open(Self.channel) } label: {
                    HStack(spacing: 7) {
                        Spacer(minLength: 0)
                        Text("Канал в Telegram")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.trailing, 20)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .frame(width: 280)
                .help("Новости и релизы Nimb в Telegram: @NimbProject")
                .accessibilityLabel("Канал Nimb в Telegram")
            }
            .frame(height: 42)
            if case .failed(let message) = updates.state {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.bad)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.black.opacity(0.28))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    /// «Версия 0.9.0 · проверено сегодня», or the offer of a newer version.
    @ViewBuilder
    private var versionLine: some View {
        switch updates.state {
        case .installing(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        case .available(let release):
            HStack(spacing: 10) {
                Text("Версия \(Updater.currentVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Button { updates.install(release) } label: {
                    Label("Обновить до \(release.version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(PressableStyle())
                .disabled(!canInstall)
            }
        default:
            Text(status)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var status: String {
        let version = "Версия \(Updater.currentVersion)"
        if case .checking = updates.state { return version + " · проверяю…" }
        guard let checked = updates.lastChecked else { return updates.lastCheckFailed ? version + " · не удалось проверить" : version }
        if updates.lastCheckFailed { return version + " · не удалось проверить" }
        return version + (Calendar.current.isDateInToday(checked) ? " · проверено сегодня" : " · проверено " + checked.formatted(.dateTime.day().month(.wide)))
    }
}
