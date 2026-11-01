import AppKit
import Foundation

/// Where reports go: a small relay that forwards them to the developer (`report-relay/` in the repository). With no address the
/// report can still be copied and sent by hand.
enum ReportConfig {
    /// `NIMB_REPORT_URL` exists for tests only.
    static var endpoint: URL? {
        if let test = ProcessInfo.processInfo.environment["NIMB_REPORT_URL"], let url = URL(string: test) { return url }
        return URL(string: "https://nimb-report.nimb-app.workers.dev/")
    }

    static var canSend: Bool { endpoint != nil && ReportGate.isOpen }
    /// The words for a window of a build that sends nothing.
    static let pausedWords = "Приложение изменено или собрано не из официального выпуска, поэтому тестирование приостановлено. Разработчик не отвечает за изменённые сборки."

    /// Where a person can write by hand when the report cannot be sent: the developer in Telegram.
    static let developerHandle = "i17th"

    /// Opens the chat with the developer: the Telegram app when it is there, the page of the chat otherwise.
    @MainActor static func openDeveloperChat() {
        let app = URL(string: "tg://resolve?domain=\(developerHandle)")
        let web = URL(string: "https://t.me/\(developerHandle)")
        if let app, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let web {
            NSWorkspace.shared.open(web)
        }
    }
    /// One Telegram message takes 4096 characters.
    static let messageLimit = 4000
}

enum ReportSender {
    struct Failure: LocalizedError {
        let errorDescription: String?
        /// The relay will never take this report (it is not signed as a release's): trying again later is no use.
        let refused: Bool
        init(_ message: String, refused: Bool = false) { errorDescription = message; self.refused = refused }
    }

    /// The relay takes at most 100 KB; a longer report loses the middle of the diary, not its head or its end.
    private static let limit = 60_000

    /// `auto` is for a report that the program sends by itself («Помогать тестированию»): the cause and the random number of the installation.
    static func send(id: String, text: String, auto: (trigger: String, install: String)? = nil) async throws {
        if let paused = ReportGate.pausedWords { throw Failure(paused, refused: true) }
        guard let key = ReportKey.data else { throw Failure(ReportConfig.pausedWords, refused: true) }
        guard let endpoint = ReportConfig.endpoint else { throw Failure("Отправка из приложения пока не настроена.") }
        var body = text
        if body.count > limit { body = String(body.prefix(limit / 2)) + "\n…\n" + String(body.suffix(limit / 2)) }
        var payload: [String: Any] = ["v": 1, "id": id, "app": Updater.currentVersion, "platform": "macos", "text": body]
        payload["sig"] = ReportSigner.signature(of: ReportSigner.message(id: id, app: Updater.currentVersion, platform: "macos", install: auto?.install ?? "", text: body), key: key)
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
        let answer: Data
        do {
            (answer, response) = try await URLSession.shared.data(for: request)
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
        case 403:
            // The relay says why: «outdated» (a newer version is out, and it names it) or a signature that is not a release's.
            let said = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
            if said?["error"] as? String == "outdated" {
                let latest = said?["latest"] as? String
                if let latest { ReportFreshness.record(latest: latest) }
                throw Failure(ReportGate.outdatedWords(latest: latest), refused: true)
            }
            throw Failure(ReportConfig.pausedWords, refused: true)
        case 429: throw Failure("Отчётов слишком много, попробуйте через несколько минут.")
        default: throw Failure("Сервер отчётов отказал (код \(http.statusCode)).")
        }
    }
}
