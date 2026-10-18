import SwiftUI

@MainActor
final class DNSViewModel: ObservableObject {
    @Published var selected: DNSProvider = DNSProvider.all[0]
    @Published var active: DNSProvider?
    @Published var isBusy = false
    @Published var errorMessage: String?

    init() { refresh() }

    func refresh() {
        let services = DNSManager.physicalServices()
        active = DNSManager.activeProvider(on: services)
        if let active { selected = active }
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
        guard !isBusy else { return }
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

struct ContentView: View {
    @StateObject private var model = DNSViewModel()

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
            .disabled(model.isBusy)
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
                    ProviderRow(provider: provider, isSelected: model.selected == provider) {
                        model.select(provider)
                    }
                }
            }
            .disabled(model.isBusy)

            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 360)
    }
}

private struct ProviderRow: View {
    let provider: DNSProvider
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.system(size: 14, weight: .semibold))
                    Text(provider.note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
