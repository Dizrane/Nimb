import SwiftUI

/// What stands under the halo on a page.
enum MascotArt: Equatable {
    /// The hooded dog of the Telegram page, a hand drawing.
    case hood
    /// A black screen with a play button and a chat bubble, drawn in the same ink: YouTube and Discord.
    case screen
}

/// The big switch of the Telegram and YouTube/Discord pages, made like the one of the DNS page: a figure under the halo
/// of Nimb. The halo comes down and the figure lights up when the service is on; a small power button sits below.
struct MascotHero: View {
    let art: MascotArt
    let isOn: Bool
    let isBusy: Bool
    let title: String
    let subtitle: String
    let accessibility: String
    var disabled = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hover = Flag()

    /// Where the crown of the figure is, relative to the middle of the stage, and how large the halo is around it.
    private let stageHeight: CGFloat = 208
    private var haloY: CGFloat { art == .hood ? -50 : -43 }
    private var haloScale: CGFloat { art == .hood ? 0.70 : 0.88 }

    var body: some View {
        let lit: Double = isOn ? 1 : 0
        let h: Double = hover.value ? 1 : 0
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.05 + 0.13 * lit + 0.04 * h * lit), .clear], center: .center, startRadius: 8, endRadius: 128))
                        .frame(width: 270, height: 270)
                        .offset(y: 4)

                    haloImage(HaloImages.shared.back)
                        .opacity(lit)
                        .offset(y: haloY + (isOn ? 0 : -18))

                    figure(lit: lit, hover: h)
                        .offset(y: 2)

                    haloImage(HaloImages.shared.front)
                        .opacity(lit)
                        .offset(y: haloY + (isOn ? 0 : -18))

                    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isOn || reduceMotion || scenePhase != .active)) { context in
                        Canvas { ctx, size in
                            let place = (center: CGPoint(x: size.width / 2, y: size.height / 2 + haloY), scale: haloScale)
                            HaloSparks.draw(&ctx, place, t: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate, spin: 1, strength: 1)
                        }
                        .allowsHitTesting(false)
                    }
                    .opacity(lit)

                    badge(hover: h).offset(y: 84)
                }
                .frame(width: 320, height: stageHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(disabled)
            .onHover { hover.value = $0 }
            .animation(.easeInOut(duration: 1.0), value: isOn)
            .animation(.easeInOut(duration: 0.4), value: hover.value)
            .accessibilityLabel(accessibility)

            Text(title)
                .font(Typo.status)
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                .contentTransition(.opacity)

            Text(subtitle)
                .font(Typo.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, minHeight: 38, alignment: .top)
        }
        .padding(.top, -6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.35), value: title)
    }

    private func haloImage(_ image: CGImage) -> some View {
        let size = HaloImages.shared.size
        return Image(decorative: image, scale: HaloImages.shared.pixelScale)
            .resizable()
            .frame(width: size.width * haloScale, height: size.height * haloScale)
            .allowsHitTesting(false)
    }

    /// The figure itself: dim and plain while off, with a light rim and a glow once on.
    @ViewBuilder
    private func figure(lit: Double, hover: Double) -> some View {
        let rim = 0.22 + 0.45 * lit + 0.15 * hover
        Group {
            switch art {
            case .hood: HoodArt()
            case .screen: ScreenArt()
            }
        }
        .shadow(color: .white.opacity(rim), radius: 1.5)
        .shadow(color: .white.opacity(0.10 + 0.22 * lit), radius: 12)
        .opacity(0.62 + 0.38 * lit)
        .scaleEffect(0.96 + 0.04 * lit)
    }

    /// The small power button under the figure, the same as the one under the planet.
    private func badge(hover: Double) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .overlay(Circle().strokeBorder((isOn ? Theme.ok : Color.white).opacity(isOn ? 0.7 : 0.30 + 0.25 * hover), lineWidth: 1))
                .frame(width: 40, height: 40)
            if isBusy {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isOn ? Theme.ok : Color.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Art

/// The hooded dog. The drawing is transparent around the hood and in the face; the face is filled with white in the file.
struct HoodArt: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "hood", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 116)
        } else {
            Image(systemName: "pawprint.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// A screen with a play button and a chat bubble. Black ink, a white face and a black "nose" like the dog, with edges
/// that wobble a little as if drawn with a marker.
struct ScreenArt: View {
    private static let ink = Color(white: 0.045)

    var body: some View {
        ZStack {
            // The black frame, the white screen and the black play button.
            InkShape(kind: .roundedRect(radius: 26), seed: 1, wobble: 1.3).fill(Self.ink)
                .frame(width: 128, height: 92)
            InkShape(kind: .roundedRect(radius: 17), seed: 2, wobble: 1.0).fill(Color(white: 0.95))
                .frame(width: 100, height: 64)
                .offset(x: -2, y: -2)
            InkShape(kind: .triangle, seed: 7, wobble: 0.8).fill(Self.ink)
                .frame(width: 30, height: 34)
                .offset(x: 1, y: -2)

            // The chat bubble with three dots.
            ZStack {
                InkShape(kind: .bubble, seed: 4, wobble: 1.1).fill(Self.ink)
                    .overlay(InkShape(kind: .bubble, seed: 4, wobble: 1.1).stroke(Color(white: 0.95), lineWidth: 2.2))
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(white: 0.95)).frame(width: 5.5, height: 5.5) }
                }
                .offset(y: -3)
            }
            .frame(width: 58, height: 46)
            .offset(x: 46, y: 38)
        }
        .frame(width: 140, height: 124)
        .rotationEffect(.degrees(-3))
    }
}

// MARK: - Ink shapes

/// A closed outline sampled along its edge, nudged by a deterministic amount and smoothed, so that it looks drawn by hand.
struct InkShape: Shape {
    enum Kind { case roundedRect(radius: CGFloat), triangle, bubble }
    let kind: Kind
    let seed: Int
    var wobble: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var points = outline(in: rect)
        for i in points.indices {
            points[i].x += noise(i * 2) * wobble
            points[i].y += noise(i * 2 + 1) * wobble
        }
        return smoothClosed(points)
    }

    private func noise(_ index: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: index &* 7919 &+ seed &* 104729) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return CGFloat(Double(x % 2001) / 1000.0 - 1.0)
    }

    private func outline(in rect: CGRect) -> [CGPoint] {
        switch kind {
        case .roundedRect(let radius):
            return roundedRectPoints(rect, radius: min(radius, min(rect.width, rect.height) / 2))
        case .triangle:
            // A play button: the point to the right.
            return subdivide([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY)], parts: 4)
        case .bubble:
            let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.80)
            var points = roundedRectPoints(body, radius: body.height / 2.2)
            // The tail: pull the lower left of the outline down to a point.
            if let i = points.indices.min(by: { distance(points[$0], CGPoint(x: rect.minX + rect.width * 0.22, y: body.maxY)) < distance(points[$1], CGPoint(x: rect.minX + rect.width * 0.22, y: body.maxY)) }) {
                points[i] = CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY)
            }
            return points
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func roundedRectPoints(_ rect: CGRect, radius r: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        func side(_ from: CGPoint, _ to: CGPoint) {
            for k in 0..<5 { let f = CGFloat(k) / 5; points.append(CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)) }
        }
        func corner(_ center: CGPoint, _ start: CGFloat) {
            for k in 0..<5 { let a = start + CGFloat(k) / 5 * (.pi / 2); points.append(CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))) }
        }
        side(CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY))
        corner(CGPoint(x: rect.maxX - r, y: rect.minY + r), -.pi / 2)
        side(CGPoint(x: rect.maxX, y: rect.minY + r), CGPoint(x: rect.maxX, y: rect.maxY - r))
        corner(CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0)
        side(CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX + r, y: rect.maxY))
        corner(CGPoint(x: rect.minX + r, y: rect.maxY - r), .pi / 2)
        side(CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX, y: rect.minY + r))
        corner(CGPoint(x: rect.minX + r, y: rect.minY + r), .pi)
        return points
    }

    private func subdivide(_ corners: [CGPoint], parts: Int) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for k in 0..<parts { let f = CGFloat(k) / CGFloat(parts); points.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)) }
        }
        return points
    }

    /// Quadratic curves between the midpoints of neighbouring points, the points being the controls: no corners left.
    private func smoothClosed(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in points.indices {
            path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
        }
        path.closeSubpath()
        return path
    }
}
