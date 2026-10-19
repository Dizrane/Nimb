import SwiftUI

/// Shows the content as it is when it fits in the room it is given, and makes it scrollable only when it does not.
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
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
