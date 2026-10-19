import SwiftUI

/// A small halo of Nimb around the top of a symbol: the back half behind it, the front half over it.
struct HaloCrown<Content: View>: View {
    var scale: CGFloat = 0.36
    @ViewBuilder let content: Content

    var body: some View {
        let size = HaloImages.shared.size
        let width = size.width * scale, height = size.height * scale
        ZStack {
            Image(decorative: HaloImages.shared.back, scale: HaloImages.shared.pixelScale)
                .resizable().frame(width: width, height: height).offset(y: -21)
            content
            Image(decorative: HaloImages.shared.front, scale: HaloImages.shared.pixelScale)
                .resizable().frame(width: width, height: height).offset(y: -21)
        }
        .frame(width: width, height: 64)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
