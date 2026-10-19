import SwiftUI

/// A picture of the art studio shown as it is: a still icon in a row, for example.
struct ArtImage: View {
    let folder: String
    let file: String
    var size: CGFloat = 30

    var body: some View {
        if let image = ArtLibrary.shared.image(folder, file) {
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

extension AppPage {
    /// The still icon of a page in a list; dimmed when the service is off.
    func iconFile(dimmed: Bool) -> (folder: String, file: String)? {
        switch self {
        case .ai: ("icon-ai", dimmed ? "flower-off.png" : "flower.png")
        case .telegram: ("icon-telegram", dimmed ? "plane-off.png" : "plane.png")
        case .media: ("icon-media", dimmed ? "play-off.png" : "play.png")
        case .settings: ("icon-gear", "gear.png")
        case .home: nil
        }
    }
}
