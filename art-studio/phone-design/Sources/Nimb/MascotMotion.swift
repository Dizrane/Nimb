import SwiftUI

/// The clocks of a hero that SwiftUI cannot animate for a canvas: how lit it is (a smooth 0...1 over a second), how much of the
/// moving extras (the plane, the sound of the screen) has appeared, and the flight of the plane. Everything is a function of the
/// time asked for, so that a frame is drawn from the clock and not from a chain of animations.
@MainActor
final class MascotMotion: ObservableObject {
    /// True while something is changing, so that the page keeps drawing a little longer after a switch.
    @Published private(set) var moving = false

    /// A value that goes to a target in one second, with a soft start and stop.
    struct Fader {
        var from = 0.0, target = 0.0, started = Date.distantPast
        func value(at date: Date) -> Double {
            let u = min(max(date.timeIntervalSince(started) / 1.0, 0), 1)
            return from + (target - from) * (u * u * (3 - 2 * u))
        }
        mutating func set(_ newTarget: Double, now: Date) {
            guard newTarget != target else { return }
            from = value(at: now); target = newTarget; started = now
        }
    }

    private var light = Fader()
    private var rings = [Fader(), Fader(), Fader()]
    private var turnedOn: Date?
    private var turnedOff: Date?
    private var movingUntil = Date.distantPast

    /// The plane flies all the time the page is shown, wherever it is; only its opacity follows the switch.
    let plane = Wanderer(seed: 0)
    private var lastStep: Date?

    func lit(at date: Date) -> Double { light.value(at: date) }
    func ring(_ i: Int, at date: Date) -> Double { rings[i].value(at: date) }

    func set(on: Bool) {
        let now = Date()
        light.set(on ? 1 : 0, now: now)
        if on { turnedOn = now; turnedOff = nil } else { turnedOff = now }
        keepMoving(for: on ? 3.0 : 1.2)
    }

    /// The home page: one ring for each service that is on.
    func set(rings count: Int) {
        let now = Date()
        for i in 0..<3 { rings[i].set(i < count ? 1 : 0, now: now) }
        light.set(count > 0 ? 1 : 0, now: now)
        keepMoving(for: 1.2)
    }

    /// How much of something that comes after the switch has appeared: it starts `delay` seconds after the switch went on and
    /// takes `duration` to come; when the switch goes off it leaves together with the light.
    func appear(at date: Date, delay: Double, duration: Double) -> Double {
        guard let start = turnedOn else { return light.value(at: date) > 0 ? 1 : 0 }
        let u = min(max((date.timeIntervalSince(start) - delay) / duration, 0), 1)
        let eased = u * u * (3 - 2 * u)
        return min(eased, light.value(at: date))
    }

    /// Moves the plane on to `date`. A long pause (the window was not shown) does not run it all the way: it just goes on.
    func advance(to date: Date, speed: Double) {
        defer { lastStep = date }
        guard let last = lastStep else { return }
        let dt = min(max(date.timeIntervalSince(last), 0), 0.1)
        if dt > 0 { plane.step(dt * speed) }
    }

    func keepMoving(for seconds: Double) {
        movingUntil = max(movingUntil, Date().addingTimeInterval(seconds))
        moving = true
        Task {
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            if Date() >= movingUntil { moving = false }
        }
    }
}
