import SwiftUI

/// Shared look of the figures: black satin lit from the upper left, a thin light rim, pearl white for the faces.
enum Satin {
    static let pearl = Gradient(colors: [Color(white: 0.99), Color(white: 0.86), Color(white: 0.66)])

    static func black(from: CGPoint, to: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: Color(white: 0.22), location: 0), .init(color: Color(white: 0.075), location: 0.45), .init(color: Color(white: 0.015), location: 1)]),
                        startPoint: from, endPoint: to)
    }

    static func rim(from: CGPoint, to: CGPoint, strength: Double = 1) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [Color.white.opacity(0.65 * strength), Color.white.opacity(0.10 * strength), Color.white.opacity(0.22 * strength)]),
                        startPoint: from, endPoint: to)
    }
}
