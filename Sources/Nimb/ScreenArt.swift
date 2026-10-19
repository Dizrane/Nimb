import SwiftUI

/// A black screen with a glowing play button and a pearl Discord mark: YouTube and Discord, in the same material as the dog.
struct ScreenArt: View {
    var body: some View {
        Canvas { ctx, size in
            let screen = CGRect(x: 13, y: 6, width: 126, height: 88)
            let bezel = Path(roundedRect: screen, cornerRadius: 24, style: .continuous)
            let display = Path(roundedRect: screen.insetBy(dx: 7, dy: 7), cornerRadius: 17, style: .continuous)

            // The bezel.
            ctx.fill(bezel, with: Satin.black(from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY)))
            ctx.stroke(bezel, with: Satin.rim(from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY)), lineWidth: 1)

            // The glass: dark, with a faint light from above and a diagonal reflection.
            ctx.fill(display, with: .linearGradient(Gradient(colors: [Color(white: 0.115), Color(white: 0.02)]),
                                                    startPoint: CGPoint(x: screen.midX, y: screen.minY), endPoint: CGPoint(x: screen.midX, y: screen.maxY)))
            ctx.drawLayer { l in
                l.clip(to: display)
                var band = Path()
                band.move(to: CGPoint(x: screen.minX + 14, y: screen.maxY))
                band.addLine(to: CGPoint(x: screen.minX + 52, y: screen.minY))
                band.addLine(to: CGPoint(x: screen.minX + 76, y: screen.minY))
                band.addLine(to: CGPoint(x: screen.minX + 38, y: screen.maxY))
                band.closeSubpath()
                l.fill(band, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.07), Color.white.opacity(0.0)]),
                                                   startPoint: CGPoint(x: screen.minX + 20, y: screen.maxY), endPoint: CGPoint(x: screen.minX + 70, y: screen.minY)))
            }
            ctx.stroke(display, with: .color(.white.opacity(0.10)), lineWidth: 0.8)

            // The play button: a pearl triangle with rounded corners, glowing.
            let c = CGPoint(x: screen.midX - 3, y: screen.midY - 1)
            var play = Path()
            play.move(to: CGPoint(x: c.x - 11, y: c.y - 17))
            play.addLine(to: CGPoint(x: c.x + 17, y: c.y))
            play.addLine(to: CGPoint(x: c.x - 11, y: c.y + 17))
            play.closeSubpath()
            let pearl = GraphicsContext.Shading.linearGradient(Satin.pearl, startPoint: CGPoint(x: c.x, y: c.y - 17), endPoint: CGPoint(x: c.x, y: c.y + 17))
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .white.opacity(0.55), radius: 9))
                l.fill(play, with: pearl)
                l.stroke(play, with: pearl, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }

            // The Discord mark: pearl, with a dark outline that separates it from the screen, and two dark eyes.
            let mark = CGRect(x: 82, y: 64, width: 66, height: 50)
            func M(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: mark.minX + x / 100 * mark.width, y: mark.minY + y / 76 * mark.height) }
            var logo = Path()
            logo.move(to: M(21, 7))
            logo.addCurve(to: M(41, 9), control1: M(29, 3), control2: M(36, 5))
            logo.addCurve(to: M(59, 9), control1: M(47, 8), control2: M(53, 8))
            logo.addCurve(to: M(79, 7), control1: M(64, 5), control2: M(71, 3))
            logo.addCurve(to: M(98, 58), control1: M(90, 15), control2: M(97, 36))
            logo.addCurve(to: M(75, 70), control1: M(91, 63), control2: M(83, 67))
            logo.addCurve(to: M(70, 62), control1: M(73, 67), control2: M(71, 64))
            logo.addCurve(to: M(30, 62), control1: M(57, 66), control2: M(43, 66))
            logo.addCurve(to: M(25, 70), control1: M(29, 64), control2: M(27, 67))
            logo.addCurve(to: M(2, 58), control1: M(17, 67), control2: M(9, 63))
            logo.addCurve(to: M(21, 7), control1: M(3, 36), control2: M(10, 15))
            logo.closeSubpath()
            ctx.stroke(logo, with: .color(.black), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            ctx.fill(logo, with: .linearGradient(Satin.pearl, startPoint: CGPoint(x: mark.midX, y: mark.minY), endPoint: CGPoint(x: mark.midX, y: mark.maxY)))
            for x in [35.0, 65.0] {
                let eye = CGRect(x: M(x, 0).x - 4.6, y: M(0, 30).y, width: 9.2, height: 12.5)
                ctx.fill(Path(ellipseIn: eye), with: .linearGradient(Gradient(colors: [Color(white: 0.30), Color(white: 0.04)]), startPoint: CGPoint(x: eye.midX, y: eye.minY), endPoint: CGPoint(x: eye.midX, y: eye.maxY)))
            }
        }
        .frame(width: 152, height: 118)
    }
}
