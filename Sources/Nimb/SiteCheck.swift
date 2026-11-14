import Foundation

/// Basic HTTP reachability of a site, its API and a public image. Playback, messages and calls need a client check.
/// One slow answer is not an outage, so the verdict looks at all of them.
struct SiteCheck: Identifiable, Equatable {
    enum Verdict { case works, partial, down }

    let name: String
    let probes: [SiteProbe]

    var id: String { name }
    var answered: Int { probes.filter(\.answered).count }

    var verdict: Verdict {
        if answered == probes.count { return .works }
        return answered == 0 ? .down : .partial
    }

    /// Median time of the answers that came.
    var seconds: Double? {
        let times = probes.filter(\.answered).map(\.seconds).sorted()
        return times.isEmpty ? nil : times[times.count / 2]
    }

    var result: String {
        switch verdict {
        case .works: "адреса доступны" + (seconds.map { " \($0.formatted(.number.precision(.fractionLength(1)))) с" } ?? "")
        case .partial: "частично: \(answered) из \(probes.count)"
        case .down: "не отвечает"
        }
    }
}
