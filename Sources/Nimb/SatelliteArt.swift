import SwiftUI

/// The satellite of Nimb: it flies in once the halo is lit and sends a beam to the thing it serves.
enum SatelliteArt {
    /// Drawn around the origin, the dish at the bottom pointing along +y; the caller rotates it towards its target.
    static func draw(_ g: inout GraphicsContext, pulse: Double) {
        for side in [-1.0, 1.0] {
            let x: CGFloat = side < 0 ? -23 : 8
            let rect = CGRect(x: x, y: -4, width: 15, height: 8)
            g.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color(white: 0.1)))
            var grid = Path()
            for i in 1..<4 {
                grid.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.minY))
                grid.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.maxY))
            }
            grid.move(to: CGPoint(x: rect.minX, y: 0)); grid.addLine(to: CGPoint(x: rect.maxX, y: 0))
            g.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            g.stroke(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.85)), lineWidth: 0.7)
        }
        var struts = Path()
        struts.move(to: CGPoint(x: -8, y: 0)); struts.addLine(to: CGPoint(x: -5, y: 0))
        struts.move(to: CGPoint(x: 5, y: 0)); struts.addLine(to: CGPoint(x: 8, y: 0))
        g.stroke(struts, with: .color(.white.opacity(0.8)), lineWidth: 1)

        let body = Path(roundedRect: CGRect(x: -5, y: -5, width: 10, height: 10), cornerRadius: 2.2)
        g.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.6)]),
                                           startPoint: CGPoint(x: -5, y: -5), endPoint: CGPoint(x: 5, y: 5)))
        g.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 0.6)

        g.fill(Path(ellipseIn: CGRect(x: -9, y: 1, width: 18, height: 18)),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.6 * pulse + 0.2), .white.opacity(0)]),
                                     center: CGPoint(x: 0, y: 10), startRadius: 0, endRadius: 9))
        g.fill(Path(ellipseIn: CGRect(x: -1.8, y: 8.2, width: 3.6, height: 3.6)), with: .color(.white))
        var dish = Path()
        dish.move(to: CGPoint(x: 0, y: 5)); dish.addLine(to: CGPoint(x: 0, y: 8.5))
        g.stroke(dish, with: .color(.white.opacity(0.9)), lineWidth: 1)
    }
}
