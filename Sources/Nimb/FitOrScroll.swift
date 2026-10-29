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

/// A popover is placed by the system next to its anchor, and one that is taller than the room under it runs past the edge of the screen
/// (behind the Dock) when the window stands low. So its height is held to a part of the smallest visible screen, and what does not fit
/// scrolls. Whatever the place of the window, the system can then move the popover to where all of it is seen.
struct FitsScreen: ViewModifier {
    var fraction: CGFloat = 0.72

    func body(content: Content) -> some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxHeight: Self.limit(fraction))
    }

    /// The height allowed: `fraction` of the smallest visible height among the screens (a popover may open on any of them), not below 260.
    static func limit(_ fraction: CGFloat, screens: [CGFloat] = NSScreen.screens.map { $0.visibleFrame.height }) -> CGFloat {
        max(260, (screens.min() ?? 700) * fraction)
    }
}

extension View {
    /// Keeps a popover within the visible part of the screen (see `FitsScreen`).
    func fitsScreen(_ fraction: CGFloat = 0.72) -> some View { modifier(FitsScreen(fraction: fraction)) }
}

extension View {
    /// The shape of every «i» of the program: the popover of the system (transparent matte glass, as in the details of a DNS provider),
    /// 14 pt of margin, a width of its own, held to the screen. The title is in the font of a name, the text small and secondary.
    func infoPanel(width: CGFloat) -> some View {
        padding(14).frame(width: width, alignment: .leading).fitsScreen()
    }
}
