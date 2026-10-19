import SwiftUI

/// The paper plane that serves the Telegram page, as the satellite serves the DNS page.
enum PaperPlaneArt {
    /// Drawn around the origin with the nose along +y; the caller rotates it towards its target.
    static func draw(_ g: inout GraphicsContext, pulse: Double) {
        // A soft glow where the engine would be.
        g.fill(Path(ellipseIn: CGRect(x: -9, y: -19, width: 18, height: 18)),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.5 * pulse + 0.15), .white.opacity(0)]),
                                     center: CGPoint(x: 0, y: -10), startRadius: 0, endRadius: 9))
        var wings = Path()
        wings.move(to: CGPoint(x: 0, y: 11))
        wings.addLine(to: CGPoint(x: -8, y: -7))
        wings.addLine(to: CGPoint(x: 0, y: -3))
        wings.addLine(to: CGPoint(x: 8, y: -7))
        wings.closeSubpath()
        g.fill(wings, with: .linearGradient(Gradient(colors: [Color(white: 0.99), Color(white: 0.62)]),
                                            startPoint: CGPoint(x: -8, y: 11), endPoint: CGPoint(x: 8, y: -7)))
        g.stroke(wings, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
        var fold = Path()
        fold.move(to: CGPoint(x: 0, y: 11))
        fold.addLine(to: CGPoint(x: 0, y: -3))
        g.stroke(fold, with: .color(.black.opacity(0.35)), lineWidth: 0.7)
    }
}
