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

/// The icon of a page in a list (a row of the sidebar, a service of the home page) with its little story: the same player as the
/// icon of the set-up steps, started by `play()` when the row is pressed. Without motion it is just the still picture.
struct PlayableIcon: View {
    let page: AppPage
    var size: CGFloat = 32
    var dimmed = false

    @ObservedObject private var gate = AnimationGate.shared
    @ObservedObject private var player: StepIconPlayer

    init(page: AppPage, size: CGFloat = 32, dimmed: Bool = false) {
        self.page = page
        self.size = size
        self.dimmed = dimmed
        _player = ObservedObject(wrappedValue: StepIconPlayers.shared.player(page.stepKind ?? .gear))
    }

    /// Starts the story of the icon of `page`.
    @MainActor
    static func play(_ page: AppPage, reduceMotion: Bool) {
        guard !reduceMotion, let kind = page.stepKind else { return }
        StepIconPlayers.shared.player(kind).play(reduceMotion: false)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || !gate.shouldRun(brief: true))) { context in
            Canvas { ctx, canvas in
                let still = page.iconFile(dimmed: dimmed)
                let image = player.frame(at: context.date) ?? still.flatMap { ArtLibrary.shared.image($0.folder, $0.file) }
                guard let image else { return }
                ctx.draw(Image(decorative: image, scale: 2), in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

extension AppPage {
    /// The story that plays on the icon of this page.
    var stepKind: StepIconKind? {
        switch self {
        case .ai: .ai
        case .telegram: .telegram
        case .media: .media
        case .settings: .gear
        case .home: nil
        }
    }
}
