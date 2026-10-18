import SwiftUI

@MainActor
final class DNSViewModel: ObservableObject {
    @Published var selected: DNSProvider = DNSProvider.all[0]
    @Published var active: DNSProvider?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var warnings: [String] = []
    @Published var isProbing = false
    @Published var probeProgress = ""
    @Published var probeFraction = 0.0
    @Published var reports: [ProviderReport] = []

    init() {
        // Read the state synchronously once, so a Mac that already has DNS on opens straight into space.
        let services = DNSManager.physicalServices()
        let current = DNSManager.activeProvider(on: services)
        active = current
        if let current {
            selected = current
            warnings = DNSManager.overrideWarnings(for: current)
        }
    }

    /// True while a DNS change or a service check is running; both need the network undisturbed.
    var isLocked: Bool { isBusy || isProbing }

    var mode: AppMode {
        if isProbing { return .probing }
        if isBusy { return .busy }
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
            await MainActor.run {
                guard !self.isLocked else { return }
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

    /// A silent check stays quiet when offline or when GitHub cannot be reached.
    func check(silent: Bool) {
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                let release = try await Updater.latestRelease()
                state = Updater.isNewer(release.version, than: Updater.currentVersion) ? .available(release) : .upToDate
            } catch {
                state = silent ? .idle : .failed("Не удалось проверить обновления: \(error.localizedDescription)")
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
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @StateObject private var model = DNSViewModel()
    @StateObject private var updates = UpdateViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Hero(model: model)
            ScrollView {
                ProvidersSection(model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            FooterBar(updates: updates, canInstall: !model.isLocked)
        }
        .frame(width: 400, height: 720)
        // As a background the scenery cannot widen the layout; it is larger than the window.
        .background { NimbBackground(lit: model.active != nil) }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .background(WindowConfigurator())
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.reports.count)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onAppear { updates.check(silent: true) }
    }
}

// MARK: - Hero

private struct Hero: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 4) {
            HeroButton(mode: model.mode, lit: model.active != nil, region: model.active?.region ?? model.selected.region, action: model.toggle)
                .disabled(model.isLocked)
                .padding(.vertical, -22)
                .accessibilityLabel(model.active == nil ? "Включить Smart DNS" : "Выключить Smart DNS")

            Text(title)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .contentTransition(.opacity)

            VStack(spacing: 3) {
                if let active = model.active, !model.isLocked {
                    Text(active.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(active.addresses.joined(separator: "   "))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 36, alignment: .top)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.35), value: model.mode)
    }

    private var title: String {
        switch model.mode {
        case .off: return "Выключено"
        case .on: return "Включено"
        case .probing: return "Проверяю сервисы"
        case .busy: return "Применяю DNS"
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .off: return "Используется DNS роутера или провайдера"
        case .on: return ""
        case .probing: return "Спрашиваю DNS и запрашиваю сайты и API"
        case .busy: return "Подтвердите пароль администратора"
        }
    }
}

// MARK: - Providers

private struct ProvidersSection: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("DNS-ПРОВАЙДЕРЫ")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                ProbeButton(model: model)
            }
            .padding(.horizontal, 2)

            if let best = model.best, best.workingCount > 0 {
                BestBanner(report: best, isSelected: model.selected == best.provider, locked: model.isLocked, action: model.selectBest)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                NoticeCard(lines: model.warnings, color: Theme.warn, symbol: "exclamationmark.triangle.fill")
            }
            if let message = model.errorMessage {
                NoticeCard(lines: [message], color: Theme.bad, symbol: "xmark.octagon.fill")
            }
        }
    }
}

private struct ProbeButton: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        Button(action: model.probe) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: geo.size.width * model.probeFraction)
                        .animation(.easeOut(duration: 0.25), value: model.probeFraction)
                }
                .opacity(model.isProbing ? 1 : 0)

                HStack(spacing: 6) {
                    Image(systemName: model.isProbing ? "dot.radiowaves.left.and.right" : "waveform.path.ecg")
                    Text(model.isProbing ? model.probeProgress : "Проверить сервисы")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
            }
            .frame(width: 184, height: 30)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
            .clipShape(Capsule())
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

    private var accent: Color { Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if isBest {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warn)
                        .help("Лучший по итогам проверки")
                }
                if isActive { Badge(text: "Активен", color: Theme.ok) }
                Spacer(minLength: 4)
                if let report {
                    SpeedBadge(seconds: report.medianSeconds)
                    Button { details.value.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Подробности проверки")
                    .popover(isPresented: $details.value, arrowEdge: .trailing) { DetailsView(report: report) }
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? accent : Color.white.opacity(0.28))
            }

            Text(provider.addresses.joined(separator: "   "))
                .font(.system(size: 12, design: .monospaced))
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
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: accent, tintOpacity: isSelected ? 0.10 : hover.value ? 0.04 : 0, borderOpacity: isSelected ? 0.32 : hover.value ? 0.16 : 0.08)
        .shadow(color: isSelected ? accent.opacity(0.22) : .clear, radius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hover.value = $0 }
        .allowsHitTesting(!locked)
        .opacity(locked ? 0.6 : 1)
        .animation(.easeOut(duration: 0.18), value: hover.value)
        .animation(.easeOut(duration: 0.25), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }
}

/// Three bars that fill up with speed, plus the time to the first byte.
private struct SpeedBadge: View {
    let seconds: Double?

    private var level: Int {
        guard let seconds else { return 0 }
        return seconds < 0.6 ? 3 : seconds < 1.2 ? 2 : 1
    }

    private var color: Color { level == 3 ? Theme.ok : level == 2 ? Theme.warn : Theme.bad }

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < level ? color : Color.white.opacity(0.18))
                        .frame(width: 3.5, height: 6 + CGFloat(i) * 4)
                }
            }
            .frame(height: 14)
            Text(seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) с" } ?? "—")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seconds.map { "Скорость \($0.formatted(.number.precision(.fractionLength(1)))) секунды" } ?? "Нет ответа")
    }
}

/// One service with a tick, a warning or a cross.
private struct ServicePill: View {
    let result: ServiceResult

    private var style: (symbol: String, color: Color) {
        switch result.status {
        case .works: return ("checkmark.circle.fill", Theme.ok)
        case .unstable: return ("exclamationmark.triangle.fill", Theme.warn)
        case .down: return ("xmark.circle.fill", Theme.bad)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: style.symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(style.color)
            Text(result.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule().fill(style.color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(style.color.opacity(0.30)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.name): \(result.status == .works ? "работает" : result.status == .unstable ? "нестабильно" : "не отвечает")")
    }
}

private struct DetailsView: View {
    let report: ProviderReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.provider.name).font(.system(size: 14, weight: .bold))
            ForEach(ProbeTarget.services, id: \.self) { service in
                HStack {
                    Text(service).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 16)
                    Text("сайт \(count(service, .site)) · API \(count(service, .api))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if !report.deadAddresses.isEmpty {
                Divider()
                Label("Не отвечают: \(report.deadAddresses.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warn)
            }
            Divider()
            Text("Цифры — сколько адресов пула ответило на запрос. Сервис работает, если ответило не менее 75%. Проверка не гарантирует, что откроются приложения.")
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
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.warn)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.warn.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Лучший: \(report.provider.name)")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Работает \(report.workingCount) из \(ProbeTarget.services.count) сервисов")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if isSelected {
                Label("Выбран", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ok)
            } else {
                Button(action: action) {
                    Text("Выбрать")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.warn))
                }
                .buttonStyle(PressableStyle())
                .disabled(locked)
            }
        }
        .padding(12)
        .glassCard(tint: Theme.warn, tintOpacity: 0.07, borderOpacity: 0.16)
    }
}

private struct NoticeCard: View {
    let lines: [String]
    let color: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: color, tintOpacity: 0.07, borderOpacity: 0.16, radius: 14)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var updates: UpdateViewModel
    let canInstall: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("RDNS \(Updater.currentVersion)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                switch updates.state {
                case .idle, .failed:
                    Button("Проверить обновления") { updates.check(silent: false) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                case .checking:
                    ProgressView().controlSize(.small)
                case .upToDate:
                    Label("Актуальная версия", systemImage: "checkmark")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                case .installing(let text):
                    ProgressView().controlSize(.small)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                case .available(let release):
                    Button { updates.install(release) } label: {
                        Label("Обновить до \(release.version)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.ok))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!canInstall)
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
