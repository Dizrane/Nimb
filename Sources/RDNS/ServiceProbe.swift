import Foundation

/// One address the check requests: a site or an API endpoint of an AI service.
struct ProbeTarget: Hashable {
    enum Kind { case site, api }

    let service: String
    let host: String
    let kind: Kind

    static let all: [ProbeTarget] = [
        ProbeTarget(service: "ChatGPT", host: "chatgpt.com", kind: .site),
        ProbeTarget(service: "ChatGPT", host: "api.openai.com", kind: .api),
        ProbeTarget(service: "Claude", host: "claude.ai", kind: .site),
        ProbeTarget(service: "Claude", host: "api.anthropic.com", kind: .api),
        ProbeTarget(service: "Gemini", host: "gemini.google.com", kind: .site),
        ProbeTarget(service: "Gemini", host: "generativelanguage.googleapis.com", kind: .api),
        ProbeTarget(service: "ElevenLabs", host: "elevenlabs.io", kind: .site),
        ProbeTarget(service: "ElevenLabs", host: "api.elevenlabs.io", kind: .api),
    ]

    /// Service names in the order of `all`, without repeats.
    static let services: [String] = all.reduce(into: []) { names, target in
        if !names.contains(target.service) { names.append(target.service) }
    }
}

/// Result of one HTTPS request to one pool address of a provider.
struct ProbeSample {
    let target: ProbeTarget
    let address: String?
    /// Time to first byte; nil when the provider returned no address or the request failed.
    let seconds: Double?

    var ok: Bool { seconds != nil }
}

enum ServiceStatus { case works, unstable, down }

/// How one AI service (its site and API together) answered through a provider.
struct ServiceResult: Identifiable {
    let name: String
    let answered: Int
    let total: Int

    var id: String { name }

    /// One dead address in a pool of five still leaves the service working, so 75% is enough.
    static let workingShare = 0.75

    var status: ServiceStatus {
        if answered == 0 { return .down }
        return Double(answered) / Double(total) >= Self.workingShare ? .works : .unstable
    }
}

struct ProviderReport: Identifiable {
    let provider: DNSProvider
    let samples: [ProbeSample]

    var id: String { provider.id }

    var services: [ServiceResult] {
        ProbeTarget.services.map { name in
            let own = samples.filter { $0.target.service == name }
            return ServiceResult(name: name, answered: own.filter(\.ok).count, total: own.count)
        }
    }

    var workingCount: Int { services.filter { $0.status == .works }.count }

    var medianSeconds: Double? {
        let times = samples.compactMap(\.seconds).sorted()
        guard !times.isEmpty else { return nil }
        return times[times.count / 2]
    }

    /// Pool addresses that did not answer a single request.
    var deadAddresses: [String] {
        let addresses = Set(samples.compactMap(\.address))
        return addresses.filter { address in !samples.contains { $0.address == address && $0.ok } }.sorted()
    }

    /// Per-service counts for the tooltip, e.g. "Claude: сайт 2/3, API 1/3".
    var details: String {
        var lines: [String] = []
        for service in ProbeTarget.services {
            func count(_ kind: ProbeTarget.Kind) -> String {
                let s = samples.filter { $0.target.service == service && $0.target.kind == kind }
                return "\(s.filter(\.ok).count)/\(s.count)"
            }
            lines.append("\(service): сайт \(count(.site)), API \(count(.api))")
        }
        let dead = deadAddresses
        if !dead.isEmpty { lines.append("Не отвечают адреса: \(dead.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// Differences in median time below this are noise and do not decide the ranking.
    static let noticeableDifference = 0.1

    /// More working services wins; at the same number a clearly faster median wins.
    func isBetter(than other: ProviderReport) -> Bool {
        if workingCount != other.workingCount { return workingCount > other.workingCount }
        return (medianSeconds ?? .infinity) < (other.medianSeconds ?? .infinity) - Self.noticeableDifference
    }
}

/// Checks how the AI services answer through each provider, without changing the system DNS:
/// the provider's DNS server is asked directly, then every address it returns is requested over HTTPS.
enum ServiceProbe {
    static func run(
        providers: [DNSProvider] = DNSProvider.all,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) -> [ProviderReport] {
        let lock = NSLock()

        // 1. Ask each provider's DNS for every target.
        let pairs = providers.indices.flatMap { p in ProbeTarget.all.map { (p, $0) } }
        var resolved = [[String]](repeating: [], count: pairs.count)
        DispatchQueue.concurrentPerform(iterations: pairs.count) { i in
            let addresses = resolve(pairs[i].1.host, using: providers[pairs[i].0].addresses)
            lock.lock(); resolved[i] = addresses; lock.unlock()
        }

        // 2. Request every returned address. A target with no usable answer counts as one failure.
        struct Job { let provider: Int; let target: ProbeTarget; let address: String? }
        var jobs: [Job] = []
        for (i, pair) in pairs.enumerated() {
            if resolved[i].isEmpty {
                jobs.append(Job(provider: pair.0, target: pair.1, address: nil))
            } else {
                jobs += resolved[i].map { Job(provider: pair.0, target: pair.1, address: $0) }
            }
        }

        var samples = [ProbeSample?](repeating: nil, count: jobs.count)
        var done = 0
        progress(0, jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let seconds = job.address.flatMap { measure(host: job.target.host, address: $0) }
            lock.lock()
            samples[i] = ProbeSample(target: job.target, address: job.address, seconds: seconds)
            done += 1
            let finished = done
            lock.unlock()
            progress(finished, jobs.count)
        }

        return providers.indices.map { p in
            ProviderReport(
                provider: providers[p],
                samples: jobs.indices.filter { jobs[$0].provider == p }.compactMap { samples[$0] }
            )
        }
    }

    /// IPv4 answers of the provider's own DNS server for `host`; the second server is a fallback.
    private static func resolve(_ host: String, using servers: [String]) -> [String] {
        for server in servers {
            let output = capture("/usr/bin/dig", ["+time=2", "+tries=1", "+short", "@\(server)", host, "A"]) ?? ""
            let addresses = output.split(separator: "\n").map(String.init).filter(isUsableIPv4)
            if !addresses.isEmpty { return addresses }
        }
        return []
    }

    private static func isUsableIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        return text != "0.0.0.0" && !text.hasPrefix("127.")
    }

    /// Time to first byte of `https://host/` sent to `address`, or nil if the request failed.
    /// Any HTTP status below 500 counts: sites often answer 403 to curl but are reachable.
    private static func measure(host: String, address: String) -> Double? {
        let output = capture("/usr/bin/curl", [
            "-s", "-o", "/dev/null", "--connect-timeout", "3", "--max-time", "6",
            "--resolve", "\(host):443:\(address)",
            "-w", "%{http_code} %{time_starttransfer}", "https://\(host)/",
        ])
        let fields = (output ?? "").split(separator: " ")
        guard fields.count == 2, let code = Int(fields[0]), let seconds = Double(fields[1]),
              (100..<500).contains(code) else { return nil }
        return seconds
    }

    /// Standard output of a command regardless of its exit status; nil if it cannot start.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
