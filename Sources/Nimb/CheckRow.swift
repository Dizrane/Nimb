import SwiftUI

/// The result for one site: a mark, its name, how it went and a small ⓘ with the details.
struct CheckRow: View {
    let check: SiteCheck
    @StateObject private var details = Flag()

    private var mark: (symbol: String, color: Color) {
        switch check.verdict {
        case .works: ("checkmark", Theme.ok)
        case .partial: ("exclamationmark.triangle", Theme.warn)
        case .down: ("xmark", Theme.bad)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                Image(systemName: mark.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(mark.color)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(check.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(check.result).font(Typo.mono).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(check.name)
            .accessibilityValue(check.result)
            Button { details.value.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Подробности проверки")
            .accessibilityLabel("Подробности проверки \(check.name)")
            .popover(isPresented: $details.value, arrowEdge: .trailing) { CheckDetails(check: check) }
        }
    }
}
