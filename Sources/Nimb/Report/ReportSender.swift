import Foundation

/// Where reports go: a small relay that forwards them to the developer (`report-relay/` in the repository). With no address the
/// report can still be copied and sent by hand.
enum ReportConfig {
    /// `NIMB_REPORT_URL` exists for tests only.
    static var endpoint: URL? {
        if let test = ProcessInfo.processInfo.environment["NIMB_REPORT_URL"], let url = URL(string: test) { return url }
        return URL(string: "https://nimb-report.nimb-app.workers.dev/")
    }

    static var canSend: Bool { endpoint != nil }

    /// Where a person can write by hand when the report cannot be sent: the developer in Telegram.
    static let developerHandle = "i17th"
    /// One Telegram message takes 4096 characters.
    static let messageLimit = 4000
}

enum ReportSender {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The relay takes at most 100 KB; a longer report loses the middle of the diary, not its head or its end.
    private static let limit = 60_000

    /// `auto` is for a report that the program sends by itself («Помогать тестированию»): the cause and the random number of the installation.
    static func send(id: String, text: String, auto: (trigger: String, install: String)? = nil) async throws {
        guard let endpoint = ReportConfig.endpoint else { throw Failure("Отправка из приложения пока не настроена.") }
        var body = text
        if body.count > limit { body = String(body.prefix(limit / 2)) + "\n…\n" + String(body.suffix(limit / 2)) }
        var payload: [String: Any] = ["v": 1, "id": id, "app": Updater.currentVersion, "platform": "macos", "text": body]
        if let auto {
            payload["auto"] = true
            payload["trigger"] = auto.trigger
            payload["install"] = auto.install
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw Failure("Сервер отчётов не ответил за 20 секунд.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw Failure("Нет интернета.")
        } catch {
            throw Failure("Не удалось соединиться с сервером отчётов.")
        }
        guard let http = response as? HTTPURLResponse else { throw Failure("Сервер отчётов ответил непонятно.") }
        switch http.statusCode {
        case 200..<300: return
        case 429: throw Failure("Отчётов слишком много, попробуйте через несколько минут.")
        default: throw Failure("Сервер отчётов отказал (код \(http.statusCode)).")
        }
    }
}
