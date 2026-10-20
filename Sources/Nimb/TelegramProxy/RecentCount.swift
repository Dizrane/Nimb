import Foundation

/// Watches a counter that only grows (connections that came with another key) and says whether it grew a moment ago. The time is given
/// by the caller, so that the rule can be tried with any clock.
struct RecentCount {
    /// How long without growth before the thing is called past.
    let quiet: TimeInterval
    private var lastCount = 0
    private var lastGrowth: Date?

    init(quiet: TimeInterval) { self.quiet = quiet }

    /// Takes the current value of the counter and returns whether it grew less than `quiet` seconds ago.
    mutating func observe(_ count: Int, at now: Date) -> Bool {
        if count > lastCount { lastGrowth = now }
        lastCount = count
        return isRecent(at: now)
    }

    func isRecent(at now: Date) -> Bool {
        guard let lastGrowth else { return false }
        return now.timeIntervalSince(lastGrowth) < quiet
    }

    /// The counter starts again (the proxy was stopped): nothing counts as recent.
    mutating func reset() {
        lastCount = 0
        lastGrowth = nil
    }
}
