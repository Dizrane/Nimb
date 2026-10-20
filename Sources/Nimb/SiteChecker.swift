import Foundation

/// Asks YouTube and Discord for small answers at several addresses each and reports what came. All requests go out at
/// once, and each address is tried by several connections at a time, the way a browser does: through the tunnel, Cloudflare
/// leaves part of the connections to Google's sites without an answer (measured at about every second one), so a single
/// connection that fails is not an outage.
enum SiteChecker {
    private static let targets: [(name: String, probes: [(String, String)])] = [
        ("YouTube", [
            ("Сайт", "https://www.youtube.com/"),
            ("Проверочный адрес", "https://www.youtube.com/generate_204"),
            ("Картинки", "https://i.ytimg.com/"),
            ("Видео", "https://redirector.googlevideo.com/"),
        ]),
        ("Discord", [
            ("Сайт", "https://discord.com/"),
            ("Служебный адрес", "https://discord.com/api/v9/gateway"),
            ("Файлы", "https://cdn.discordapp.com/"),
            ("Сообщения", "https://gateway.discord.gg/"),
        ]),
    ]

    static func run() async -> [SiteCheck] {
        await withTaskGroup(of: (Int, Int, SiteProbe).self) { group in
            for (i, target) in targets.enumerated() {
                for (j, probe) in target.probes.enumerated() {
                    group.addTask { (i, j, await answer(name: probe.0, url: probe.1)) }
                }
            }
            var found: [Int: [Int: SiteProbe]] = [:]
            for await (i, j, probe) in group { found[i, default: [:]][j] = probe }
            return targets.enumerated().map { i, target in
                SiteCheck(name: target.name, probes: target.probes.indices.compactMap { found[i]?[$0] })
            }
        }
    }

    /// Connections tried at once for one address, and how many times that is repeated while none of them has answered.
    private static let attempts = 4
    private static let rounds = 2

    /// The fastest answer of a round of simultaneous connections; the next round only if none of them answered.
    private static func answer(name: String, url: String) async -> SiteProbe {
        var failed: SiteProbe?
        for _ in 0..<rounds {
            let round = await withTaskGroup(of: SiteProbe.self) { group in
                for _ in 0..<attempts { group.addTask { await Task.detached { curl(name: name, url: url) }.value } }
                var all: [SiteProbe] = []
                for await result in group { all.append(result) }
                return all
            }
            if let best = round.filter(\.answered).min(by: { $0.seconds < $1.seconds }) { return best }
            failed = round.first
        }
        return failed ?? SiteProbe(name: name, url: url, code: 0, seconds: 0, failure: "нет ответа")
    }

    /// `curl` prints the code and the time; its exit status says why there was no answer.
    nonisolated private static func curl(name: String, url: String) -> SiteProbe {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-o", "/dev/null", "-m", "8", "--connect-timeout", "5", "-w", "%{http_code} %{time_total}", url]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else {
            return SiteProbe(name: name, url: url, code: 0, seconds: 0, failure: "не удалось запустить проверку")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        let fields = String(decoding: data, as: UTF8.self).split(separator: " ")
        let code = fields.first.flatMap { Int($0) } ?? 0
        let seconds = fields.count > 1 ? Double(fields[1]) ?? 0 : 0
        guard process.terminationStatus == 0 else {
            return SiteProbe(name: name, url: url, code: 0, seconds: seconds, failure: reason(for: process.terminationStatus))
        }
        return SiteProbe(name: name, url: url, code: code, seconds: seconds, failure: code == 0 ? "нет ответа" : nil)
    }

    nonisolated private static func reason(for status: Int32) -> String {
        switch status {
        case 6: "не нашлось адреса сайта"
        case 7: "не удалось соединиться"
        case 28: "время ожидания вышло"
        case 35, 51, 58, 60: "ошибка защищённого соединения"
        case 52, 56: "соединение оборвалось"
        default: "ошибка проверки (\(status))"
        }
    }
}
