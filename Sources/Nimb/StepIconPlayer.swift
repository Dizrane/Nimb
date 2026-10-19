import SwiftUI

/// Plays the sequence of a step icon when it is tapped. Taps during the sequence are ignored.
@MainActor
final class StepIconPlayer: ObservableObject {
    let kind: StepIconKind
    @Published private(set) var isPlaying = false
    /// For "Reduce Motion": the icon shows its second picture for a while instead of moving.
    @Published private(set) var showsSecond = false
    private(set) var started = Date.distantPast
    private(set) var taps = 0

    init(kind: StepIconKind) { self.kind = kind }

    func play(reduceMotion: Bool) {
        guard !isPlaying else { return }
        taps += 1
        started = Date()
        isPlaying = true
        if reduceMotion {
            guard kind.second != nil else { isPlaying = false; return }
            showsSecond = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                showsSecond = false
                isPlaying = false
            }
            return
        }
        // The pictures of the sequence are loaded now, not before the first tap.
        for segment in kind.segments { _ = ArtLibrary.shared.sequence(kind.folder, pattern: segment.pattern, frames: segment.frames) }
        _ = ArtLibrary.shared.image("icon-ai", "planet.png")
        Task {
            try? await Task.sleep(for: .seconds(kind.duration + 0.05))
            isPlaying = false
        }
    }

    func elapsed(at date: Date) -> Double { max(date.timeIntervalSince(started), 0) }

    /// The picture of the sequence at a moment, or nil when it is not playing.
    func frame(at date: Date) -> CGImage? {
        guard isPlaying else { return nil }
        var t = elapsed(at: date)
        for segment in kind.segments {
            if t < segment.seconds { return picture(segment, t) }
            t -= segment.seconds
        }
        guard let last = kind.segments.last else { return nil }
        return picture(last, last.seconds)
    }

    private func picture(_ segment: StepIconKind.Segment, _ t: Double) -> CGImage? {
        let index = min(Int(t / segment.seconds * Double(segment.frames)), segment.frames - 1)
        return ArtLibrary.shared.image(kind.folder, String(format: segment.pattern, segment.reversed ? segment.frames - 1 - index : index))
    }
}
