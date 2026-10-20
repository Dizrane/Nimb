import SwiftUI

/// Shows the content as it is when it fits in the room it is given (centred in it), and makes it scrollable only when it does not.
/// The pages of the desktop window are made to fit, so the scrolling is a safety for a small window or an unusual amount of text.
struct FitOrScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
