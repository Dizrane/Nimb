import SwiftUI

/// The timing of the small flying thing of a page: it comes in after the figure is lit, stays at its station and leaves
/// faster than it came. Same behaviour as the satellite of the DNS page.
@MainActor
final class MascotMotion: ObservableObject {
    /// True while something is still moving, so that the page keeps redrawing a little longer after the switch.
    @Published private(set) var moving = false

    private var on = false
    private var from = 0.0
    private var started = Date.distantPast
    private var movingUntil = Date.distantPast
    private let inTime = 2.6
    private let outTime = 0.8

    /// 0 gone, 1 at its station.
    func orbiter(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(started)
        if on { return min(max(from + max(elapsed - 0.25, 0) / inTime, 0), 1) }
        return min(max(from - elapsed / outTime, 0), 1)
    }

    func set(on newValue: Bool) {
        let now = Date()
        from = orbiter(at: now)
        on = newValue
        started = now
        keepMoving(for: newValue ? 0.25 + inTime + 0.2 : outTime + 0.2)
    }

    private func keepMoving(for seconds: Double) {
        movingUntil = max(movingUntil, Date().addingTimeInterval(seconds))
        moving = true
        Task {
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            if Date() >= movingUntil { moving = false }
        }
    }
}
