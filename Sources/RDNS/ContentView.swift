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
    @Published var reports: [ProviderReport] = []

    init() { refresh() }

    /// True while a DNS change or a service check is running; both need the network undisturbed.
    var isLocked: Bool { isBusy || isProbing }

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
        reports = []
        Task.detached {
            let result = ServiceProbe.run { done, total in
                Task { @MainActor in
                    if self.isProbing { self.probeProgress = "Проверено \(done) из \(total)" }
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

struct ContentView: View {
    @StateObject private var model = DNSViewModel()
    @StateObject private var updates = UpdateViewModel()

    var body: some View {
        VStack(spacing: 22) {
            Text("RDNS")
                .font(.system(size: 22, weight: .heavy, design: .rounded))

            Button(action: model.toggle) {
                ZStack {
                    Circle()
                        .fill(model.active == nil ? Color.gray.opacity(0.35) : Color.green)
                        .frame(width: 150, height: 150)
                        .shadow(color: model.active == nil ? .clear : .green.opacity(0.5), radius: 18)
                    if model.isBusy {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isLocked)
            .accessibilityLabel(model.active == nil ? "Включить Smart DNS" : "Выключить Smart DNS")

            VStack(spacing: 4) {
                Text(model.active == nil ? "Выключено" : "Включено: \(model.active!.name)")
                    .font(.headline)
                Text(model.active == nil ? "Используется DNS роутера или провайдера" : model.active!.addresses.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(DNSProvider.all) { provider in
                    ProviderRow(
                        provider: provider,
                        report: model.report(for: provider),
                        isSelected: model.selected == provider
                    ) {
                        model.select(provider)
                    }
                }
            }
            .disabled(model.isLocked)

            ProbeSection(model: model)

            if !model.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Divider()
            UpdateSection(updates: updates, canInstall: !model.isLocked)
        }
        .padding(28)
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onAppear { updates.check(silent: true) }
    }
}

private struct ProbeSection: View {
    @ObservedObject var model: DNSViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button(action: model.probe) {
                    Label("Проверить сервисы", systemImage: "waveform.path.ecg")
                }
                .disabled(model.isLocked)
                if model.isProbing {
                    ProgressView().controlSize(.small)
                    Text(model.probeProgress).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let best = model.best, best.workingCount > 0 {
                Button("Выбрать лучший: \(best.provider.name)", action: model.selectBest)
                    .disabled(model.isLocked)
                Text("Лучший — тот, через который отвечает больше сервисов, при равенстве — быстрее. Проверка показывает, отвечают ли сайты и API, но не гарантирует, что откроются приложения.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UpdateSection: View {
    @ObservedObject var updates: UpdateViewModel
    let canInstall: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("RDNS \(Updater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                switch updates.state {
                case .idle, .failed:
                    Button("Проверить обновления") { updates.check(silent: false) }
                        .buttonStyle(.link)
                        .font(.caption)
                case .checking:
                    ProgressView().controlSize(.small)
                case .upToDate:
                    Text("Актуальная версия").font(.caption).foregroundStyle(.secondary)
                case .installing(let text):
                    ProgressView().controlSize(.small)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .available(let release):
                    Text("Доступна версия \(release.version)").font(.caption).foregroundStyle(.green)
                }
            }

            if case .available(let release) = updates.state {
                Button("Обновить и перезапустить") { updates.install(release) }
                    .disabled(!canInstall)
            }
            if case .failed(let message) = updates.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: DNSProvider
    let report: ProviderReport?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider.name).font(.system(size: 14, weight: .semibold))
                    if let report {
                        ServiceList(results: report.services)
                    } else {
                        Text(provider.addresses.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .opacity(isSelected ? 1 : 0)
                    if let report {
                        Text(report.medianSeconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) с" } ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(report?.details ?? "")
    }
}

/// Which services answered through the provider: a tick, a warning or a cross next to each name.
private struct ServiceList: View {
    let results: [ServiceResult]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            ForEach(Array(stride(from: 0, to: results.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(results[start..<min(start + 2, results.count)]) { item($0) }
                }
            }
        }
    }

    private func item(_ result: ServiceResult) -> some View {
        let symbol: String, color: Color
        switch result.status {
        case .works: (symbol, color) = ("checkmark.circle.fill", .green)
        case .unstable: (symbol, color) = ("exclamationmark.triangle.fill", .orange)
        case .down: (symbol, color) = ("xmark.circle.fill", .red)
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(result.name)
        }
        .font(.caption)
    }
}
