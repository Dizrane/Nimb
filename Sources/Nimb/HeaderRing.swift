import SwiftUI

/// The ring of Nimb in the header of the window: one small halo that goes round the word of the selected tab (drawn round it like
/// with a pen, clockwise from the left), and on the home tab a stack of three small rings, one for each service. Ported from
/// `art-studio/deliver/header/header-motion.js`; both halves of the ring lie behind the labels.
@MainActor
final class HeaderRing: ObservableObject {
    struct Pose: Equatable {
        var x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat
    }

    /// True while the ring is travelling, so that the header is drawn faster for that time.
    @Published private(set) var moving = false

    static let tween = 0.9
    static let oldFade = 3.0
    private var from: Pose?
    private var to: Pose?
    private var started = Date.distantPast
    private var tab: AppPage?

    /// The place the ring should be for the selected tab. Called when the tab changes and when the labels get their places.
    func update(tab newTab: AppPage, pose: Pose) {
        if tab == nil || to == nil {
            to = pose; from = nil; tab = newTab
            return
        }
        if newTab != tab {
            from = to; to = pose; tab = newTab; started = Date()
            moving = true
            Task {
                try? await Task.sleep(for: .seconds(Self.tween + 0.1))
                if Date().timeIntervalSince(started) >= Self.tween { moving = false }
            }
        } else {
            to = pose
        }
    }

    func state(at date: Date) -> (from: Pose?, to: Pose?, raw: Double) {
        (from, to, min(date.timeIntervalSince(started) / Self.tween, 1))
    }

    // MARK: Drawing

    private static func smoother(_ u: Double) -> Double { u * u * u * (u * (u * 6 - 15) + 10) }

    /// One half of the ring at a pose; `reveal` below 1 draws it round the word like a pen (a wedge clip from the left, clockwise).
    private static func drawRing(_ ctx: inout GraphicsContext, part: HeaderPart, pose: Pose, alpha: Double, reveal: Double?) {
        guard alpha > 0.003, let image = ArtLibrary.shared.image("header", part.file) else { return }
        ctx.drawLayer { layer in
            layer.translateBy(x: pose.x, y: pose.y)
            layer.scaleBy(x: pose.rx / 80, y: pose.ry / 25)
            if let reveal, reveal < 1 {
                var wedge = Path()
                wedge.move(to: .zero)
                let steps = max(Int(reveal * 90), 2)
                for i in 0...steps {
                    let a = Double.pi + 2 * Double.pi * reveal * Double(i) / Double(steps)
                    wedge.addLine(to: CGPoint(x: 600 * cos(a), y: 600 * sin(a)))
                }
                wedge.closeSubpath()
                layer.clip(to: wedge)
            }
            layer.opacity = alpha
            layer.blendMode = .plusLighter
            layer.draw(Image(decorative: image, scale: 2), in: CGRect(x: -168, y: -97, width: 336, height: 194))
        }
    }

    /// One frame of the ring round the selected word.
    func drawSelection(_ ctx: inout GraphicsContext, date: Date, reduceMotion: Bool) {
        let s = state(at: date)
        guard let to = s.to else { return }
        let t = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let breathe = 0.93 + 0.07 * sin(t * 1.7)
        if reduceMotion {
            // No drawing: the old ring gives way to the new one in 0.3 s.
            let u = min(date.timeIntervalSince(started) / 0.3, 1)
            if let from = s.from, u < 1 { for part in HeaderPart.allCases { Self.drawRing(&ctx, part: part, pose: from, alpha: breathe * (1 - u), reveal: nil) } }
            for part in HeaderPart.allCases { Self.drawRing(&ctx, part: part, pose: to, alpha: breathe * (s.from == nil ? 1 : u), reveal: nil) }
            return
        }
        if s.raw < 1, let from = s.from {
            let fade = max(1 - s.raw * Self.oldFade, 0)
            for part in HeaderPart.allCases { Self.drawRing(&ctx, part: part, pose: from, alpha: breathe * fade, reveal: nil) }
            let u = Self.smoother(s.raw)
            for part in HeaderPart.allCases { Self.drawRing(&ctx, part: part, pose: to, alpha: breathe, reveal: u) }
        } else {
            for part in HeaderPart.allCases { Self.drawRing(&ctx, part: part, pose: to, alpha: breathe, reveal: nil) }
        }
    }

    /// The home tab: three small rings one above another, in a box of 26 x 20 points centred on `center`. As many are lit as
    /// there are services working, and they go out from the top: the lowest ring is the last one left (as in the hero of the home page).
    static func drawStack(_ ctx: inout GraphicsContext, center: CGPoint, count: Int, selected: Bool) {
        for i in 0..<3 {
            let scale = 0.105 - 0.004 * Double(i)
            let cy = center.y - 10 + 4.4 + 5.4 * Double(i)
            let alpha = 2 - i < count ? (selected ? 1.0 : 0.82) : 0.14
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
