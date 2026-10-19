import SwiftUI

/// The halo of Nimb as delivered by the art studio: two halves of the ring (the far one behind a figure, the near one in front
/// of it), a plainer near half for the lower rings of a stack, and a loop of dust and streaks that slides along the ring.
enum HaloArt {
    enum Part: String { case back = "back.png", front = "front.png", frontPlain = "front-plain.png" }

    /// The canvas of every half, in points, and where the middle of the ring is on it.
    static let size = CGSize(width: 336, height: 194)
    static let center = CGPoint(x: 168, y: 97)
    /// Half width of the ring at scale 1.
    static let rx: CGFloat = 80

    private static let sparkleFrames = 24
    private static let sparkleFPS = 8.0
    /// The sparkle frames are cropped around the ring: where, on the canvas of the halo, and how large (points).
    private static let sparkleOrigin = CGPoint(x: 66, y: 47)
    private static let sparkleSize = CGSize(width: 204, height: 100)

    /// One half of the ring, centred on `center`. Light is added to what is below it.
    static func draw(_ part: Part, in ctx: inout GraphicsContext, center ring: CGPoint, scale: CGFloat, opacity: Double) {
        guard opacity > 0.003, let image = ArtLibrary.shared.image("halo", part.rawValue) else { return }
        let rect = CGRect(x: ring.x - center.x * scale, y: ring.y - center.y * scale, width: size.width * scale, height: size.height * scale)
        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.blendMode = .screen
            layer.draw(Image(decorative: image, scale: 2), in: rect)
        }
    }

    /// The loop of dust and streaks along the ring (3 seconds, 8 frames a second, the neighbouring frames dissolve into each other).
    /// `time` is in seconds and may be sped up while a service is switching.
    static func drawSparkle(in ctx: inout GraphicsContext, center ring: CGPoint, scale: CGFloat, opacity: Double, time: Double) {
        guard opacity > 0.003 else { return }
        let frames = ArtLibrary.shared.sequence("halo", pattern: "sparkle-%02d.png", frames: sparkleFrames)
        guard frames.count == sparkleFrames else { return }
        let position = (time * sparkleFPS).truncatingRemainder(dividingBy: Double(sparkleFrames))
        let first = Int(position), mix = position - Double(first)
        let rect = CGRect(x: ring.x - center.x * scale + sparkleOrigin.x * scale, y: ring.y - center.y * scale + sparkleOrigin.y * scale,
                          width: sparkleSize.width * scale, height: sparkleSize.height * scale)
        ctx.drawLayer { layer in
            layer.blendMode = .screen
            layer.opacity = opacity * (1 - mix)
            layer.draw(Image(decorative: frames[first], scale: 2), in: rect)
            layer.opacity = opacity * mix
            layer.draw(Image(decorative: frames[(first + 1) % sparkleFrames], scale: 2), in: rect)
        }
    }

    /// The first frame, for "Reduce Motion": the halo does not move.
    static func drawStill(in ctx: inout GraphicsContext, center ring: CGPoint, scale: CGFloat, opacity: Double) {
        drawSparkle(in: &ctx, center: ring, scale: scale, opacity: opacity, time: 0)
    }
}
