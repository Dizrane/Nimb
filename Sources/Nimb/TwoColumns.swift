import SwiftUI

/// The layout of a page of the desktop window: the figure of the page (planet, dog, screen) in a column on the left and what
/// belongs to it in a wider column on the right, side by side, so that the page fits the window without scrolling.
struct TwoColumns<Left: View, Right: View>: View {
    var leftWidth: CGFloat = 320
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        FitOrScroll {
            HStack(alignment: .center, spacing: Space.xl) {
                left
                    .frame(width: leftWidth)
                right
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
