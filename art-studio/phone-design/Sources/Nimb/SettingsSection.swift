import SwiftUI

/// A titled group of cards on the settings page.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .sectionLabel()
                .padding(.horizontal, 2)
            VStack(spacing: Space.s + 2) {
                content
            }
        }
    }
}
