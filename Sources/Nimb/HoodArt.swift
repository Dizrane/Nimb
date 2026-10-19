import SwiftUI

/// The hooded dog of the Telegram page: a satin black hood, a pearl face and a glossy nose, drawn from curves.
struct HoodArt: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }

            var hood = Path()
            hood.move(to: P(0.52, 0.012))
            hood.addCurve(to: P(0.955, 0.60), control1: P(0.60, 0.012), control2: P(0.90, 0.25))
            hood.addCurve(to: P(0.99, 0.945), control1: P(0.985, 0.72), control2: P(1.0, 0.85))
            hood.addCurve(to: P(0.01, 0.945), control1: P(0.80, 1.012), control2: P(0.20, 1.012))
            hood.addCurve(to: P(0.045, 0.60), control1: P(0.0, 0.85), control2: P(0.015, 0.72))
            hood.addCurve(to: P(0.52, 0.012), control1: P(0.10, 0.25), control2: P(0.43, 0.012))
            hood.closeSubpath()

            var face = Path()
            face.move(to: P(0.50, 0.585))
            face.addCurve(to: P(0.185, 0.66), control1: P(0.42, 0.485), control2: P(0.22, 0.49))
            face.addCurve(to: P(0.50, 0.935), control1: P(0.15, 0.81), control2: P(0.28, 0.90))
            face.addCurve(to: P(0.815, 0.66), control1: P(0.72, 0.90), control2: P(0.85, 0.81))
            face.addCurve(to: P(0.50, 0.585), control1: P(0.78, 0.49), control2: P(0.58, 0.485))
            face.closeSubpath()

            // The hood: a clean black shape lit from the upper left, with one thin rim of light.
            ctx.fill(hood, with: Satin.black(from: P(0.15, 0.05), to: P(0.95, 1.0)))
            ctx.drawLayer { l in
                l.clip(to: hood)
                l.fill(Path(ellipseIn: CGRect(x: -0.1 * w, y: -0.05 * h, width: 0.95 * w, height: 0.75 * h)),
                       with: .radialGradient(Gradient(colors: [Color.white.opacity(0.13), .clear]), center: P(0.32, 0.22), startRadius: 0, endRadius: 0.5 * w))
            }
            ctx.stroke(hood, with: Satin.rim(from: P(0.1, 0.1), to: P(0.95, 0.95)), lineWidth: 1)

            // The face: pearl, with the shadow of the hood falling on its upper edge.
            ctx.fill(face, with: .linearGradient(Satin.pearl, startPoint: P(0.5, 0.52), endPoint: P(0.5, 0.95)))
            ctx.drawLayer { l in
                l.clip(to: face)
                l.translateBy(x: 0, y: 0.03 * h)
                l.addFilter(.blur(radius: 0.03 * h))
                l.stroke(face, with: .color(.black.opacity(0.5)), lineWidth: 0.09 * w)
            }
            ctx.stroke(face, with: .color(.black.opacity(0.55)), lineWidth: 0.8)

            // The nose: glossy black with a small light on it.
            let nose = CGRect(x: 0.35 * w, y: 0.685 * h, width: 0.30 * w, height: 0.19 * h)
            ctx.fill(Path(ellipseIn: nose), with: .radialGradient(
                Gradient(colors: [Color(white: 0.34), Color(white: 0.05), Color(white: 0.0)]),
                center: CGPoint(x: nose.minX + nose.width * 0.38, y: nose.minY + nose.height * 0.25), startRadius: 0, endRadius: nose.width * 0.7))
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 1))
                l.fill(Path(ellipseIn: CGRect(x: nose.minX + nose.width * 0.2, y: nose.minY + nose.height * 0.12, width: nose.width * 0.34, height: nose.height * 0.22)),
                       with: .color(.white.opacity(0.5)))
            }
        }
        .frame(width: 94, height: 118)
    }
}
