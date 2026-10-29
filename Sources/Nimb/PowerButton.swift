import SwiftUI

/// The power button of the pages of a service. With the service off it is the whole page: a large dark disc with a fine ring, in the
/// middle. Switching on, the ring lights up white where it is, then the button grows small and settles in the place under the figure,
/// where it stays, white, as the switch-off button. One number, `progress`, runs all of it (0 off, 1 on) along a straight line of
/// time, and the two parts are cut out of it: the ring lights up in the first third, the button travels in the rest. Going back
/// is the same road the other way: the button comes back first and the ring goes dim last.
struct PowerButton: View, Animatable {
    var progress: Double
    var hover: Double
    let busy: Bool
    /// Where the middle of the button is when it is large, and when it is small.
    let restY: CGFloat
    let settledY: CGFloat

    private let large: CGFloat = 112
    private let small: CGFloat = 40

    /// How long the whole road takes, switching on and off.
    static let onDuration = 1.7
    static let offDuration = 1.4
    /// How far into the road the button starts to travel, as a share of it.
    static let travelStart = 0.28

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, hover) }
        set { progress = newValue.first; hover = newValue.second }
    }

    private static func ease(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }

    var body: some View {
        let glow = Self.ease(progress / 0.3)
        let travel = Self.ease((progress - Self.travelStart) / (1 - Self.travelStart))
        // The ring burns brightest while the button is still large and calms down on its way.
        let flare = glow * (1 - travel)
        let size = large + (small - large) * travel
        let ringOpacity = (0.30 + 0.25 * hover) * (1 - glow) + glow * (0.75 + 0.20 * flare)
        let glyphOpacity = 0.85 + 0.15 * max(glow, hover)
        return ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .shadow(color: .black.opacity(0.4 * (1 - travel)), radius: 12, y: 6)
            Circle()
                .strokeBorder(Color.white.opacity(ringOpacity), lineWidth: 1.4 - 0.4 * travel)
                .shadow(color: .white.opacity(0.55 * flare + 0.12 * glow), radius: size * 0.14)
            if busy {
                ProgressView().controlSize(travel < 0.5 ? .regular : .small).tint(.white)
            } else {
                Image(systemName: "power")
                    .font(.system(size: 40 - 23 * travel, weight: .regular))
                    .foregroundStyle(Color.white.opacity(glyphOpacity))
            }
        }
        .frame(width: size, height: size)
        .offset(y: restY + (settledY - restY) * travel)
    }
}

extension View {
    /// The animations of a `PowerButton`: the long road when `on` changes, the slow brightening of the ring under the pointer.
    func powerButtonAnimation(on: Bool, hovering: Bool) -> some View {
        animation(.linear(duration: on ? PowerButton.onDuration : PowerButton.offDuration), value: on)
            .animation(.easeInOut(duration: 0.45), value: hovering)
    }
}

extension PowerButton {
    /// The middle of the large button and of the small one, from the middle of the stage (`HeroLayout`): the same on every page.
    static let restY: CGFloat = 32
    static let settledY: CGFloat = 90
}

/// What the pages of a service share, so that the figure, the button and the words stand at the same height on all of them and
/// nothing jumps when the page is changed: a stage for the figure, the title under it and a place of fixed height for the lines below.
enum HeroLayout {
    static let stageHeight: CGFloat = 218
    static let subtitleHeight: CGFloat = 54
}
