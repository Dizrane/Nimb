import SwiftUI

/// A short paragraph in a card, the building block of the pages below the big switch.
struct InfoCard: View {
    let title: String
    let text: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Typo.name)
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(Typo.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(tint == .white ? .neutral : .ok)
    }
}
