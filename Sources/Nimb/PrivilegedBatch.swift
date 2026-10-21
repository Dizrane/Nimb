import Foundation

/// Jobs for root that are asked for at nearly the same moment, done under one password. «Turn everything on» changes DNS and starts the
/// tunnel, and each of them wants the administrator password: the person would type it twice. The caller says `expect(2)` first; the two
/// calls of `run` that follow go to root in one script, and each gets its own answer or error, as if it had run alone. With no
/// `expect`, a call goes at once and alone.
final class PrivilegedBatch: @unchecked Sendable {
    /// Runs a script as root and returns what it printed; throws when it fails or the password is refused.
    typealias Runner = (String) throws -> String

    static let shared = PrivilegedBatch { try DNSManager.runPrivilegedNow($0) }

    private final class Job {
        let script: String
        let finished = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(DNSError.failed("Команда не была выполнена."))
        init(_ script: String) { self.script = script }
    }

    private let runner: Runner
    /// Where root keeps its notes while the jobs run (a test uses another place).
    private let workFolder: String
    private let lock = NSLock()
    private var expected = 0
    private var round = 0
    private var waiting: [Job] = []

    init(workFolder: String = "/var/run", runner: @escaping Runner) {
        self.workFolder = workFolder
        self.runner = runner
    }

    /// The next `count` calls of `run` are done together if they all come within `seconds`; those that have come by then are done anyway.
    func expect(_ count: Int, within seconds: TimeInterval = 3) {
        lock.lock()
        expected = count
        round += 1
        let mine = round
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            let jobs = round == mine ? takeWaiting() : []
            lock.unlock()
            if !jobs.isEmpty { execute(jobs) }
        }
    }

    /// Waits for its turn and for the answer of root; blocks the thread it is called on.
    func run(_ script: String) throws -> String {
        let job = Job(script)
        lock.lock()
        var ready: [Job] = []
        if expected > 0 {
            waiting.append(job)
            if waiting.count >= expected { ready = takeWaiting() }
        } else {
            ready = [job]
        }
        lock.unlock()
        if !ready.isEmpty { execute(ready) }
        job.finished.wait()
        return try job.result.get()
    }

    /// Needs the lock. Ends the waiting: a timer that was set for it finds the round changed and does nothing.
    private func takeWaiting() -> [Job] {
        let jobs = waiting
        waiting = []
        expected = 0
        round += 1
        return jobs
    }

    private func execute(_ jobs: [Job]) {
        if jobs.count == 1 {
            jobs[0].result = Result { try runner(jobs[0].script) }
        } else {
            do {
                let output = try runner(Self.combined(jobs.map(\.script), in: workFolder))
                for (job, result) in zip(jobs, Self.results(in: output, count: jobs.count)) { job.result = result }
            } catch {
                for job in jobs { job.result = .failure(error) }
            }
        }
        jobs.forEach { $0.finished.signal() }
    }

    // MARK: One script for several

    /// Each script runs in a shell of its own, with its own stdout and stderr. For each one a line says how it went:
    /// `NIMB-RESULT <number> <exit code> x<base64 of stdout> x<base64 of stderr>` (the `x` keeps an empty field a field). The script
    /// itself always ends well, so that the lines come back even when a job fails.
    static func combined(_ scripts: [String], in workFolder: String = "/var/run") -> String {
        var lines = ["e=$(/usr/bin/mktemp '\(workFolder)/nimb-batch.XXXXXX')"]
        for (number, script) in scripts.enumerated() {
            lines.append("o=$(/bin/sh -c \(DNSManager.shellQuote(script)) 2>\"$e\"); c=$?")
            lines.append("printf 'NIMB-RESULT \(number) %s x%s x%s\\n' \"$c\" \"$(printf %s \"$o\" | /usr/bin/base64 | /usr/bin/tr -d '\\n')\" \"$(/usr/bin/base64 < \"$e\" | /usr/bin/tr -d '\\n')\"")
            lines.append(": > \"$e\"")
        }
        lines.append("/bin/rm -f \"$e\"")
        lines.append("exit 0")
        return lines.joined(separator: "; ")
    }

    /// What `combined` printed, as one result per script: what it printed, or the failure with its error text.
    static func results(in output: String, count: Int) -> [Result<String, Error>] {
        var found: [Int: Result<String, Error>] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("NIMB-RESULT ") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 5, let number = Int(fields[1]), let code = Int(fields[2]),
                  fields[3].hasPrefix("x"), fields[4].hasPrefix("x") else { continue }
            let out = decode(fields[3].dropFirst()), err = decode(fields[4].dropFirst())
            if code == 0 {
                found[number] = .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                found[number] = .failure(DNSError.failed(message.isEmpty ? "Команда завершилась с кодом \(code)." : message))
            }
        }
        return (0..<count).map { found[$0] ?? .failure(DNSError.failed("Не удалось прочитать ответ.")) }
    }

    private static func decode(_ text: Substring) -> String {
        Data(base64Encoded: String(text)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
