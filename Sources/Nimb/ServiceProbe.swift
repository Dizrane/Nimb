import Foundation

/// One address the check requests: a site or an API endpoint of an AI service.
struct ProbeTarget: Hashable {
    enum Kind { case site, api }

    let service: String
    let host: String
    let kind: Kind
    var path = "/"

    /// The APIs are asked without a key: a service that lets the request in answers "no key" (401, or 400/404), a
    /// service that refuses the region or the address answers 403 or a block page. The sites sit behind a browser check,
    /// so for them the answer mostly shows that they can be reached.
    static let all: [ProbeTarget] = [
        ProbeTarget(service: "ChatGPT", host: "chatgpt.com", kind: .site),
        ProbeTarget(service: "ChatGPT", host: "api.openai.com", kind: .api, path: "/v1/models"),
        ProbeTarget(service: "Claude", host: "claude.ai", kind: .site),
        ProbeTarget(service: "Claude", host: "api.anthropic.com", kind: .api, path: "/v1/models"),
        ProbeTarget(service: "Gemini", host: "gemini.google.com", kind: .site, path: "/app"),
        ProbeTarget(service: "Gemini", host: "generativelanguage.googleapis.com", kind: .api, path: "/v1beta/models?key=nimb-probe"),
        ProbeTarget(service: "Grok", host: "grok.com", kind: .site),
        ProbeTarget(service: "Grok", host: "api.x.ai", kind: .api, path: "/v1/models"),
        ProbeTarget(service: "ElevenLabs", host: "elevenlabs.io", kind: .site),
        ProbeTarget(service: "ElevenLabs", host: "api.elevenlabs.io", kind: .api, path: "/v1/models"),
        ProbeTarget(service: "Perplexity", host: "www.perplexity.ai", kind: .site),
        ProbeTarget(service: "Perplexity", host: "api.perplexity.ai", kind: .api, path: "/v1/models"),
    ]

    /// Service names in the order of `all`, without repeats.
    static let services: [String] = all.reduce(into: []) { names, target in
        if !names.contains(target.service) { names.append(target.service) }
    }
}

/// How one request ended.
enum ProbeOutcome: Equatable {
    /// The service answered as it does to a visitor it lets in; the time to the first byte.
    case ok(Double)
    /// The service answered, but with a refusal: another region, an address it does not trust, a limit.
    case blocked(String)
    /// No answer, or a server error.
    case failed
}

/// Result of one HTTPS request to one pool address of a provider.
struct ProbeSample {
    let target: ProbeTarget
    let address: String?
    let outcome: ProbeOutcome
    var failureReason: String? = nil

    /// Time to first byte of a normal answer.
    var seconds: Double? { if case .ok(let seconds) = outcome { return seconds } else { return nil } }
    var ok: Bool { seconds != nil }
    var blockReason: String? { if case .blocked(let reason) = outcome { return reason } else { return nil } }
}

enum ServiceStatus { case works, unstable, down, blocked }

/// How one AI service (its site and API together) answered through a provider.
struct ServiceResult: Identifiable {
    let name: String
    let answered: Int
    /// Requests that were answered with a refusal (region, address, limit).
    let blocked: Int
    let total: Int
    /// The site and API must each pass: a large API pool cannot hide a broken site, or vice versa.
    var hasFailingTarget = false

    var id: String { name }

    /// One dead address in a pool of five still leaves the service working, so 75% is enough.
    static let workingShare = 0.75

    var status: ServiceStatus {
        if answered == 0 { return blocked > 0 ? .blocked : .down }
        // A dead address is skipped by the browser, but a refusal page is not: it hits every visit that lands on that address.
        if blocked > 0 || hasFailingTarget { return .unstable }
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
            let failingTarget = [ProbeTarget.Kind.site, .api].contains { kind in
                let target = own.filter { $0.target.kind == kind }
                return target.isEmpty || Double(target.filter(\.ok).count) / Double(target.count) < ServiceResult.workingShare
            }
            return ServiceResult(name: name, answered: own.filter(\.ok).count, blocked: own.filter { $0.blockReason != nil }.count, total: own.count,
                                 hasFailingTarget: failingTarget)
        }
    }

    var workingCount: Int { services.filter { $0.status == .works }.count }

    var medianSeconds: Double? {
        let times = samples.compactMap(\.seconds).sorted()
        guard !times.isEmpty else { return nil }
        return times[times.count / 2]
    }

    /// Refusals with the address and the reason, e.g. "Gemini · 143.20.64.192: перенаправление на google.com/sorry".
    var refusals: [String] {
        var seen = Set<String>(), lines: [String] = []
        for sample in samples {
            guard let reason = sample.blockReason else { continue }
            let line = "\(sample.target.service) · \(sample.address ?? "?"): \(reason)"
            if seen.insert(line).inserted { lines.append(line) }
        }
        return lines
    }

    /// Keep transport failures distinct from DNS failures and refusals returned by the AI service.
    var failures: [String] {
        var counts: [String: Int] = [:]
        for sample in samples where sample.outcome == .failed {
            let reason = sample.address == nil ? "DNS: не получен IPv4-адрес" : (sample.failureReason ?? "HTTPS: нет нормального ответа")
            counts[reason, default: 0] += 1
        }
        return counts.keys.sorted().map { "\($0) — запросов: \(counts[$0]!)" }
    }

    /// Pool addresses that did not give a normal answer to a single request.
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
        lines += refusals.map { "Отказ: \($0)" }
        lines += failures.map { "Сбой: \($0)" }
        let dead = deadAddresses
        if !dead.isEmpty { lines.append("Без нормального ответа адреса: \(dead.joined(separator: ", "))") }
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
        providers: [DNSProvider] = DNSProvider.available,
        resolver: @escaping (String, [String]) -> [String] = resolve,
        requester: ((ProbeTarget, String) -> ProbeOutcome)? = nil,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) -> [ProviderReport] {
        let lock = NSLock()
        let pairs = providers.indices.flatMap { p in ProbeTarget.all.map { (p, $0) } }
        var samples = [[ProbeSample?]](repeating: [], count: pairs.count)
        var resolved = 0, total = 0, done = 0
        // HTTPS can start as soon as a target resolves. A silent DNS provider must not hold the other providers at a global barrier.
        let queues = providers.map { _ -> OperationQueue in
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = perProvider
            queue.qualityOfService = .utility
            return queue
        }
        progress(0, 0)
        inLanes(pairs.count, lanes: providers.count, laneOf: { pairs[$0].0 }) { i in
            let (p, target) = pairs[i]
            let addresses = resolver(target.host, providers[p].addresses)
            let jobs: [String?] = addresses.isEmpty ? [nil] : addresses.map { $0 }
            lock.lock()
            samples[i] = [ProbeSample?](repeating: nil, count: jobs.count)
            total += jobs.count
            resolved += 1
            // The denominator is final only after every DNS answer; callbacks stay ordered under the same lock.
            if resolved == pairs.count { progress(done, total) }
            lock.unlock()
            for (j, address) in jobs.enumerated() {
                queues[p].addOperation {
                    var outcome = ProbeOutcome.failed
                    var failure: String?
                    if let address {
                        func attempt() -> (outcome: ProbeOutcome, failure: String?) {
                            if let requester { return (requester(target, address), nil) }
                            let result = request(target, address: address)
                            return (result.outcome, result.failure)
                        }
                        // A timeout belongs to this host and request, never to every host sharing the address.
                        (outcome, failure) = attempt()
                        if outcome == .failed { (outcome, failure) = attempt() }
                    }
                    lock.lock()
                    samples[i][j] = ProbeSample(target: target, address: address, outcome: outcome, failureReason: failure)
                    done += 1
                    if resolved == pairs.count { progress(done, total) }
                    lock.unlock()
                }
            }
        }
        queues.forEach { $0.waitUntilAllOperationsAreFinished() }
        return providers.indices.map { p in
            ProviderReport(provider: providers[p], samples: pairs.indices.filter { pairs[$0].0 == p }.flatMap { samples[$0].compactMap { $0 } })
        }
    }

    /// Limit concurrency per provider while checking providers side by side.
    static let perProvider = 16

    /// Runs `work` for 0..<count. Each lane (a provider) has `perLane` workers of its own; the lanes go side by side. Returns when all
    /// are done.
    static func inLanes(_ count: Int, lanes: Int, laneOf: (Int) -> Int, perLane: Int = perProvider, _ work: @escaping (Int) -> Void) {
        // Dispatch can retain a worker block briefly after group.leave(); its captured work really is escaping.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "nimb.probe", attributes: .concurrent)
        for lane in 0..<lanes {
            let indices = (0..<count).filter { laneOf($0) == lane }
            let next = Counter()
            for _ in 0..<min(perLane, indices.count) {
                group.enter()
                queue.async {
                    while let k = next.take(below: indices.count) { work(indices[k]) }
                    group.leave()
                }
            }
        }
        group.wait()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func take(below limit: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard value < limit else { return nil }
            defer { value += 1 }
            return value
        }
    }

    /// IPv4 answers of the provider's own DNS server for `host`; the second server is a fallback.
    private static func resolve(_ host: String, using servers: [String]) -> [String] {
        for _ in 0..<2 {
            for server in servers {
                let output = capture("/usr/bin/dig", ["+time=2", "+tries=1", "+short", "@\(server)", host, "A"]) ?? ""
                let addresses = output.split(separator: "\n").map(String.init).filter(isUsableIPv4)
                if !addresses.isEmpty { return addresses }
            }
        }
        return []
    }

    private static func isUsableIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        return text != "0.0.0.0" && !text.hasPrefix("127.")
    }

    private static let marker = "@@NIMB@@"

    /// What curl printed after the body: the status code, the time to the first byte, the size, and the time it took to connect (0 when it
    /// could not).
    struct Trailer: Equatable {
        let code: Int
        let seconds: Double
        let size: Int
        let connected: Bool
    }

    /// The trailer and the text before it, or nil when there is no trailer (curl did not even start).
    static func splitTrailer(_ output: String) -> (head: String, trailer: Trailer)? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let fields = output[range.upperBound...].split(separator: " ")
        guard fields.count == 4, let code = Int(fields[0]), let seconds = Double(fields[1]), let size = Int(fields[2]),
              let connect = Double(fields[3]) else { return nil }
        return (String(output[..<range.lowerBound]), Trailer(code: code, seconds: seconds, size: size, connected: connect > 0))
    }

    /// Requests the target at `address` (the provider's proxy) and judges the answer. `connected` is false when no connection could be made:
    /// this request did not connect (it says nothing about other hosts or later attempts at that IP).
    private static func request(_ target: ProbeTarget, address: String) -> (outcome: ProbeOutcome, connected: Bool, failure: String?) {
        let result = captureResult("/usr/bin/curl", [
            "-q", "--noproxy", "*", "-s", "-i", "--connect-timeout", "3", "--max-time", "6",
            "--resolve", "\(target.host):443:\(address)",
            "-w", "\n\(marker)%{http_code} %{time_starttransfer} %{size_download} %{time_connect}",
            "https://\(target.host)\(target.path)",
        ])
        guard let result, let (head, trailer) = splitTrailer(result.output) else {
            return (.failed, false, "Проверка: не удалось получить результат curl")
        }
        let (headers, body) = parse(head)
        let outcome = classify(target, code: trailer.code, seconds: trailer.seconds, bodySize: trailer.size, headers: headers, body: body)
        return (outcome, trailer.connected, outcome == .failed ? failureReason(exitStatus: result.status, httpCode: trailer.code) : nil)
    }

    static func failureReason(exitStatus: Int32, httpCode: Int) -> String {
        switch exitStatus {
        case 28: return "HTTPS: истекло время ожидания соединения или ответа"
        case 35: return "TLS: не удалось установить защищённое соединение"
        case 51, 58, 60: return "TLS: ошибка проверки сертификата"
        case 52, 55, 56: return "HTTPS: соединение прервано"
        case 7: return "HTTPS: не удалось соединиться с адресом"
        default: return httpCode > 0 ? "HTTP: ответ \(httpCode)" : "HTTPS: нет ответа"
        }
    }

    /// Headers (lower-cased names) and the start of the body of the final response in `curl -i` output. Interim
    /// responses such as 103 Early Hints come first and carry none of the headers that matter.
    static func parse(_ message: String) -> (headers: [String: String], body: String) {
        var rest = Substring(message)
        while let split = rest.range(of: "\r\n\r\n") {
            let block = rest[..<split.lowerBound]
            rest = rest[split.upperBound...]
            let status = block.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            if (100..<200).contains(status) { continue }
            var headers: [String: String] = [:]
            for line in block.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return (headers, String(rest.prefix(30_000)))
        }
        return ([:], "")
    }

    /// Words in a redirect address that mark a page about restrictions rather than the service itself.
    private static let refusalWords = ["sorry", "restrict", "region", "countr", "unavailable", "blocked", "denied", "forbidden", "not-available"]

    /// Phrases the services use when they turn a region or an address away. Lower case.
    private static let refusalPhrases = [
        "unsupported_country", "country, region, or territory not supported", "not available in your country",
        "isn't available in your country", "not available in your region", "isn't available in your region",
        "not supported in your country", "not supported in your region", "unavailable in your", "not available in your location",
        "user location is not supported", "request not allowed", "access denied",
    ]

    /// Tells a normal answer from a refusal. A page that merely loads is not a success: a status below 500 used to be
    /// enough, which counted "not available in your region" as working.
    static func classify(_ target: ProbeTarget, code: Int, seconds: Double, bodySize: Int, headers: [String: String], body: String) -> ProbeOutcome {
        if code < 100 || code >= 500 { return .failed }

        if let location = headers["location"], !location.isEmpty, let url = URL(string: location), let host = url.host, host != target.host {
            let lower = location.lowercased()
            if host.hasPrefix("help.") || host.hasPrefix("support.") || refusalWords.contains(where: lower.contains) {
                return .blocked("перенаправление на \(host)\(url.path.hasPrefix("/sorry") ? "/sorry" : "")")
            }
        }
        if code == 451 { return .blocked("451: недоступно по юридическим причинам") }
        if code == 429 { return .blocked("429: слишком много запросов с этого адреса") }
        if code == 403 {
            // Cloudflare asks a browser to prove itself; the address is let in, only curl is not a browser.
            if headers["cf-mitigated"] != nil { return .ok(seconds) }
            return .blocked("403: доступ закрыт")
        }
        if target.kind == .site && code >= 400 { return .failed }
        // Refusal pages are short; the big pages of the apps carry such phrases only inside their translations.
        let isJSON = headers["content-type"]?.contains("json") == true
        if bodySize < 30_000 || isJSON {
            let lower = body.lowercased()
            if let phrase = refusalPhrases.first(where: lower.contains) { return .blocked("«\(phrase)»") }
        }
        return .ok(seconds)
    }

    /// Standard output of a command regardless of its exit status; nil if it cannot start.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        captureResult(path, args)?.output
    }

    private static func captureResult(_ path: String, _ args: [String]) -> (output: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
