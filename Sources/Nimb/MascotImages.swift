import SwiftUI

/// The figures of the pages as pictures, drawn once: with their glow and rim for "on", plain and dim for "off". A page
/// then only moves and cross-fades two bitmaps, which costs the processor almost nothing, instead of drawing curves and
/// blurs again on every frame.
@MainActor
final class MascotImages {
    static let shared = MascotImages()

    struct Picture {
        let image: CGImage
        /// Size in points.
        let size: CGSize
    }

    private(set) var hoodOn: Picture?
    private(set) var hoodOff: Picture?
    private(set) var screenOn: Picture?
    private(set) var screenOff: Picture?

    private init() {
        hoodOn = render(HoodArt(), rim: 0.67, glow: 1)
        hoodOff = render(HoodArt(), rim: 0.22, glow: 0)
        screenOn = render(ScreenArt().scaleEffect(0.8), rim: 0.67, glow: 1)
        screenOff = render(ScreenArt().scaleEffect(0.8), rim: 0.22, glow: 0)
    }

    func pictures(for art: MascotArt) -> (on: Picture, off: Picture)? {
        switch art {
        case .hood: if let on = hoodOn, let off = hoodOff { return (on, off) }
        case .screen: if let on = screenOn, let off = screenOff { return (on, off) }
        case .power: break
        }
        return nil
    }

    private func render<Content: View>(_ content: Content, rim: Double, glow: Double) -> Picture? {
        // Room around the figure for its glow.
        let styled = content
            .shadow(color: .white.opacity(rim * 0.8), radius: 1)
            .shadow(color: .white.opacity(0.08 + 0.16 * glow), radius: 10)
            .opacity(0.62 + 0.38 * glow)
            .scaleEffect(0.96 + 0.04 * glow)
            .padding(28)
        let renderer = ImageRenderer(content: styled)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return Picture(image: image, size: CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
