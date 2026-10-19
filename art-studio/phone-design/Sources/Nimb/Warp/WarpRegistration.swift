import CryptoKit
import Foundation

/// An anonymous Cloudflare WARP account made for this Mac, and the settings of the tunnel that go with it.
struct WarpAccount {
    let id: String
    let token: String
    /// The text of `warp.conf` for the helper: the shared preset from the app, this account's keys, and the account itself
    /// (the helper needs `account_id` and `account_token` only to delete the account again).
    let file: String
}

/// Makes the personal part of the tunnel. The camouflage and the routes are the same for everybody and travel inside the
/// app (`warp-preset.conf`); the keys and the address are made here, on this Mac, by registering with Cloudflare the same
/// way the official WARP app does. Nothing about the person is sent: a fresh public key and the time of the registration.
enum WarpRegistration {
    /// Two names of the same service: some networks let one of them through and not the other.
    private static let hosts = ["zero-trust-client.cloudflareclient.com", "api.cloudflareclient.com"]
    private static let apiVersion = "v0a2223"
    /// The port the camouflage of the preset is made for.
    private static let endpointPort = 500
    private static let idPattern = #"^[0-9A-Za-z-]{8,64}$"#

    static func register() async throws -> WarpAccount {
        guard let url = Bundle.main.url(forResource: "warp-preset", withExtension: "conf"),
              let preset = try? String(contentsOf: url, encoding: .utf8) else {
            throw WarpConfigError("В этой сборке Nimb нет заготовки туннеля (warp-preset.conf).")
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let body: [String: Any] = [
            "key": privateKey.publicKey.rawRepresentation.base64EncodedString(),
            "install_id": "", "fcm_token": "",
            "tos": ISO8601DateFormatter().string(from: Date()),
            "type": "Android", "model": "PC", "locale": "en_US",
        ]

        var lastProblem = "нет ответа"
        for host in hosts {
            do {
                let reply = try await send("POST", host: host, path: "/\(apiVersion)/reg", token: nil, json: body)
                guard reply.status == 200, let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else {
                    lastProblem = "ответ \(reply.status)"
                    continue
                }
                return try account(from: object, privateKey: privateKey, preset: preset)
            } catch let error as WarpConfigError {
                throw error
            } catch {
                lastProblem = error.localizedDescription
            }
        }
        throw WarpConfigError("Не удалось получить у Cloudflare личные ключи WARP (\(lastProblem)). Проверьте интернет и попробуйте ещё раз. Если Cloudflare закрыт в вашей сети, вставьте готовые настройки вручную.")
    }

    /// Deletes the account at Cloudflare, when it was made but the tunnel was not installed. Best effort.
    static func delete(_ account: WarpAccount) async {
        for host in hosts {
            if let reply = try? await send("DELETE", host: host, path: "/\(apiVersion)/reg/\(account.id)", token: account.token, json: nil),
               (200..<300).contains(reply.status) || reply.status == 404 { return }
        }
    }

    // MARK: Pieces

    private static func account(from object: [String: Any], privateKey: Curve25519.KeyAgreement.PrivateKey, preset: String) throws -> WarpAccount {
        guard let id = object["id"] as? String, let token = object["token"] as? String,
              id.range(of: idPattern, options: .regularExpression) != nil,
              token.range(of: idPattern, options: .regularExpression) != nil,
              let config = object["config"] as? [String: Any],
              let interface = config["interface"] as? [String: Any],
              let addresses = interface["addresses"] as? [String: Any],
              let peer = (config["peers"] as? [[String: Any]])?.first,
              let peerKey = peer["public_key"] as? String,
              let endpoint = peer["endpoint"] as? [String: Any],
              let v4 = endpoint["v4"] as? String, let ip = v4.split(separator: ":").first.map(String.init) else {
            throw WarpConfigError("Cloudflare вернул неожиданный ответ при создании ключей WARP.")
        }

        var addressLines: [String] = []
        if let v4 = addresses["v4"] as? String { addressLines.append("\(v4)/32") }
        if let v6 = addresses["v6"] as? String { addressLines.append("\(v6)/128") }

        // Interface part: this Mac's key and address first, then the shared preset (it has no [Peer] part before the marker).
        let parts = preset.components(separatedBy: "[Peer]")
        guard parts.count == 2 else { throw WarpConfigError("Заготовка туннеля повреждена.") }
        var text = "[Interface]\nPrivateKey = \(privateKey.rawRepresentation.base64EncodedString())\nAddress = \(addressLines.joined(separator: ", "))\n"
        text += parts[0].replacingOccurrences(of: "[Interface]", with: "")
        text += "\n[Peer]\nPublicKey = \(peerKey)\nEndpoint = \(ip):\(endpointPort)\n" + parts[1]

        // Everything passes through the same checks as a configuration that a person pastes in.
        let parsed = try WarpConfig.parse(text)
        return WarpAccount(id: id, token: token, file: parsed.file + "account_id=\(id)\naccount_token=\(token)\n")
    }

    private static func send(_ method: String, host: String, path: String, token: String?, json: [String: Any]?) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("okhttp/3.12.1", forHTTPHeaderField: "User-Agent")
        request.setValue("1.1.1.1/6.81", forHTTPHeaderField: "CF-Client-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
