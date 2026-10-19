import Foundation

/// The icons of the steps of the first set-up and of the rows of the home page, as delivered by the art studio
/// (`Art/icon-*`): a still, a dimmed still and a sequence that plays when the icon is tapped.
enum StepIconKind {
    case welcome, ai, telegram, media, gear

    /// One numbered run of pictures inside a sequence: its folder pattern, how many pictures, how long it lasts, and whether it
    /// is played backwards.
    struct Segment {
        let pattern: String
        let frames: Int
        let seconds: Double
        var reversed = false
    }

    var folder: String {
        switch self {
        case .welcome: "icon-welcome"
        case .ai: "icon-ai"
        case .telegram: "icon-telegram"
        case .media: "icon-media"
        case .gear: "icon-gear"
        }
    }

    var still: String {
        switch self {
        case .welcome: "disc.png"
        case .ai: "flower.png"
        case .telegram: "plane.png"
        case .media: "play.png"
        case .gear: "gear.png"
        }
    }

    var dimmed: String {
        switch self {
        case .welcome: "disc-off.png"
        case .ai: "flower-off.png"
        case .telegram: "plane-off.png"
        case .media: "play-off.png"
        case .gear: "gear-off.png"
        }
    }

    /// What the icon turns into (for "Reduce Motion", where it only cross-fades).
    var second: String? {
        switch self {
        case .welcome, .gear: nil
        case .ai: "planet.png"
        case .telegram: "face.png"
        case .media: "mark.png"
        }
    }

    /// The sequence that plays on a tap, in order.
    var segments: [Segment] {
        switch self {
        case .welcome: []
        case .ai:
            [Segment(pattern: "change-%02d.png", frames: 24, seconds: 1.0),
             Segment(pattern: "rest-%02d.png", frames: 48, seconds: 2.0),
             Segment(pattern: "change-%02d.png", frames: 24, seconds: 1.0, reversed: true)]
        case .telegram:
            [Segment(pattern: "out-%02d.png", frames: 30, seconds: 1.25),
             Segment(pattern: "rest-%02d.png", frames: 10, seconds: 2.0),
             Segment(pattern: "in-%02d.png", frames: 30, seconds: 1.25)]
        case .media:
            [Segment(pattern: "change-%02d.png", frames: 24, seconds: 1.0),
             Segment(pattern: "rest-%02d.png", frames: 24, seconds: 2.0),
             Segment(pattern: "change-%02d.png", frames: 24, seconds: 1.0, reversed: true)]
        case .gear:
            [Segment(pattern: "turn-%02d.png", frames: 24, seconds: 1.0)]
        }
    }

    /// How long a tap plays.
    var duration: Double { self == .welcome ? WelcomeScan.total : segments.reduce(0) { $0 + $1.seconds } }
}
