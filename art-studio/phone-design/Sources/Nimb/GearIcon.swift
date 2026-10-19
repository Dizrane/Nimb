import SwiftUI

/// The gear of the settings button in the header: the picture of the art studio, drawn from the same player as the gear of
/// the set-up step, so that it turns when the button is pressed.
struct GearIcon: View {
    @ObservedObject private var player = StepIconPlayers.shared.player(.gear)
    @ObservedObject private var gate = AnimationGate.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || !gate.shouldRun(brief: true))) { context in
            Canvas { ctx, size in
                let image = player.frame(at: context.date) ?? ArtLibrary.shared.image("icon-gear", "gear.png")
                guard let image else { return }
                ctx.draw(Image(decorative: image, scale: 2), in: CGRect(x: size.width / 2 - 18.5, y: size.height / 2 - 18.5, width: 37, height: 37))
            }
        }
        .allowsHitTesting(false)
    }
}
