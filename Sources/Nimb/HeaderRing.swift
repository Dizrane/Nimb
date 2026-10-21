import SwiftUI

/// The small rings of the home row of the sidebar: three rings one above another, lit from the bottom up as services start working.
/// The pictures are the ones of `art-studio/deliver/header`.
enum HeaderRing {
    /// The home row: three small rings one above another, in a box of 26 x 20 points centred on `center`. As many are lit as
    /// there are services working, and they go out from the top: the lowest ring is the last one left (as in the hero of the home page).
    /// How much of its light a ring keeps when it is not lit: the same share as the dimmed pictures of the services (`*-off.png`).
    static let dimmed = 0.47

    static func drawStack(_ ctx: inout GraphicsContext, center: CGPoint, count: Int, selected: Bool) {
        for i in 0..<3 {
            let scale = 0.105 - 0.004 * Double(i)
            let cy = center.y - 10 + 4.4 + 5.4 * Double(i)
            let lit = selected ? 1.0 : 0.82
            let alpha = 2 - i < count ? lit : lit * dimmed
            for part in HeaderPart.allCases {
                guard let image = ArtLibrary.shared.image("header", part.file) else { continue }
                ctx.drawLayer { layer in
                    layer.opacity = alpha
                    layer.blendMode = .plusLighter
                    layer.draw(Image(decorative: image, scale: 2),
                               in: CGRect(x: center.x - 168 * scale, y: cy - 97 * scale, width: 336 * scale, height: 194 * scale))
                }
            }
        }
    }
}

/// The two halves of the header ring.
enum HeaderPart: CaseIterable {
    case back, front
    var file: String { self == .back ? "ring-back.png" : "ring-front.png" }
}
