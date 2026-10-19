import Foundation
import Network

/// Numbers shown in the window and the menu.
struct TelegramProxyStats: Equatable {
    var totalConnections = 0
    var activeConnections = 0
    var webSocket = 0
    var directTCP = 0
    var failures = 0
    /// Connections that did not know this proxy's secret: a client set up for another proxy on the same port.
    var wrongSecret = 0
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
}

/// A local MTProto proxy for Telegram Desktop. The client talks to `127.0.0.1`; this side opens the same session to
/// Telegram's WebSocket gateway (`kws<N>.web.telegram.org`), which networks slow down far less than plain MTProto, and
/// falls back to a direct TCP connection to the data center. Ported from TG WS Proxy by Flowseal (MIT).
final class TelegramProxyEngine: @unchecked Sendable {
    /// Data centers that are reached through the WebSocket gateway at this address (the defaults of TG WS Proxy).
    static let webSocketAddress: [Int: String] = [2: "149.154.167.220", 4: "149.154.167.220"]
    static let dataCenterAddress: [Int: String] = [1: "149.154.175.50", 2: "149.154.167.51", 3: "149.154.175.100",
                                                   4: "149.154.167.91", 5: "149.154.171.5", 203: "91.105.192.100"]
    static let testDataCenterAddress: [Int: String] = [1: "149.154.175.10", 2: "149.154.167.40", 3: "149.154.175.117"]

    private let secret: Data
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Channel] = [:]
    private var stats = TelegramProxyStats()
    private var stopped = true
    private let pool = WebSocketPool()
    private let queue = DispatchQueue(label: "nimb.telegram.listener")

    private(set) var port: UInt16 = 0
    var onLog: (@Sendable (String) -> Void)?

    init(secretHex: String) {
        var bytes = Data()
        var index = secretHex.startIndex
        while index < secretHex.endIndex, let next = secretHex.index(index, offsetBy: 2, limitedBy: secretHex.endIndex) {
            bytes.append(UInt8(secretHex[index..<next], radix: 16) ?? 0)
            index = next
        }
        secret = bytes
    }

    var snapshot: TelegramProxyStats { locked { stats } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Starts listening on `127.0.0.1`, on `preferredPort` or the next free port after it. Returns the port.
    func start(preferredPort: UInt16) async throws -> UInt16 {
        locked { stopped = false; stats = TelegramProxyStats() }
        var lastError: Error = ChannelError("нет свободного порта")
        for candidate in preferredPort..<(preferredPort + 20) {
            do {
                try await listen(on: candidate)
                port = candidate
                log("Слушаю 127.0.0.1:\(candidate)")
                Task { await pool.warmUp(engine: self) }
                return candidate
            } catch {
                lastError = error
            }
        }
        locked { stopped = true }
        throw lastError
    }

    private func listen(on port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.handle(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            @Sendable func finish(_ result: Result<Void, Error>) {
                once { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(ChannelError("слушатель закрыт")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        locked { self.listener = listener }
    }

    func stop() {
        let (listener, open): (NWListener?, [Channel]) = locked {
            stopped = true
            defer { self.listener = nil; sessions.removeAll() }
            return (self.listener, Array(sessions.values))
        }
        listener?.cancel()
        open.forEach { $0.cancel() }
        Task { await pool.closeAll() }
        log("Остановлен")
    }

    var isRunning: Bool { locked { !stopped } }

    // MARK: One client

    private func handle(_ connection: NWConnection) async {
        let client = Channel(connection: connection)
        let id = ObjectIdentifier(client)
        locked { sessions[id] = client; stats.totalConnections += 1; stats.activeConnections += 1 }
        defer {
            client.cancel()
            locked { sessions[id] = nil; stats.activeConnections -= 1 }
        }
        do {
            try await client.start(timeout: 10)
            let header = try await withTimeout(10) { try await client.receiveExactly(MTProto.handshakeLength) }
            guard let handshake = MTProto.parse(header, secret: secret) else {
                count { $0.wrongSecret += 1 }
                log("Неверное рукопожатие (чужой secret или протокол)")
                return
            }
            let dcIndex = handshake.isMedia ? -handshake.dc : handshake.dc
            let relayInit = MTProto.makeRelayInit(tag: handshake.tag, dcIndex: dcIndex)
            let ciphers = MTProto.makeCiphers(handshake: handshake, secret: secret, relayInit: relayInit)
            let tag = "DC\(handshake.dc)\(handshake.isMedia ? " media" : "")"

            if !handshake.isTestDC, let ws = await pool.take(dc: handshake.dc, isMedia: handshake.isMedia, engine: self) {
                count { $0.webSocket += 1 }
                log("\(tag) → WebSocket")
                try await ws.send(relayInit)
                await bridge(client: client, ciphers: ciphers, transport: handshake.transport, ws: ws)
                return
            }

            let table = handshake.isTestDC ? Self.testDataCenterAddress : Self.dataCenterAddress
            guard let address = table[handshake.dc] else {
                count { $0.failures += 1 }
                log("\(tag): неизвестный дата-центр")
                return
            }
            log("\(tag) → прямое TCP \(address)")
            let remote = try await Channel.openTCP(address: address, port: 443, timeout: 10)
            defer { remote.cancel() }
            try await remote.send(relayInit)
            count { $0.directTCP += 1 }
            await bridge(client: client, ciphers: ciphers, transport: handshake.transport, remote: remote)
        } catch {
            count { $0.failures += 1 }
            log("Ошибка соединения: \(error.localizedDescription)")
        }
    }

    // MARK: Bridging

    private func bridge(client: Channel, ciphers: MTProto.Ciphers, transport: MTProto.Transport, ws: WebSocketClient) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                var splitter = MessageSplitter(transport: transport)
                do {
                    while true {
                        guard let chunk = try await client.receive() else {
                            if let tail = splitter.flush().first { try await ws.send(tail) }
                            return
                        }
                        if chunk.isEmpty { continue }
                        count { $0.bytesUp += Int64(chunk.count) }
                        let plain = ciphers.fromClient.update(chunk)
                        let encrypted = ciphers.toTelegram.update(plain)
                        let parts = splitter.split(cipher: encrypted, plain: plain)
                        if parts.count > 1 { try await ws.sendBatch(parts) } else if let part = parts.first { try await ws.send(part) }
                    }
                } catch {}
            }
            group.addTask { [self] in
                do {
                    while let message = try await ws.receive() {
                        count { $0.bytesDown += Int64(message.count) }
                        try await client.send(ciphers.toClient.update(ciphers.fromTelegram.update(message)))
                    }
                } catch {}
            }
            await group.next()
            client.cancel()
            ws.close()
            group.cancelAll()
        }
    }

    private func bridge(client: Channel, ciphers: MTProto.Ciphers, transport: MTProto.Transport, remote: Channel) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                do {
                    while let chunk = try await client.receive() {
                        if chunk.isEmpty { continue }
                        count { $0.bytesUp += Int64(chunk.count) }
                        try await remote.send(ciphers.toTelegram.update(ciphers.fromClient.update(chunk)))
                    }
                } catch {}
            }
            group.addTask { [self] in
                do {
                    while let chunk = try await remote.receive() {
                        if chunk.isEmpty { continue }
                        count { $0.bytesDown += Int64(chunk.count) }
                        try await client.send(ciphers.toClient.update(ciphers.fromTelegram.update(chunk)))
                    }
                } catch {}
            }
            await group.next()
            client.cancel()
            remote.cancel()
            group.cancelAll()
        }
    }

    // MARK: Helpers

    private func count(_ change: (inout TelegramProxyStats) -> Void) {
        locked { change(&stats) }
    }

    func log(_ message: String) { onLog?(message) }

    static func webSocketDomains(dc: Int, isMedia: Bool) -> [String] {
        let number = dc == 203 ? 2 : dc
        return isMedia ? ["kws\(number)-1.web.telegram.org", "kws\(number).web.telegram.org"] : ["kws\(number).web.telegram.org"]
    }
}

/// Ready WebSocket connections to the gateway, so that a client does not wait for a TLS handshake.
actor WebSocketPool {
    private struct Key: Hashable { let dc: Int; let isMedia: Bool }
    private var idle: [Key: [WebSocketClient]] = [:]
    private var refilling: Set<Key> = []
    private var failures: [Key: Int] = [:]
    private var retryAfter: [Key: Date] = [:]
    private var tryFrontingFirst = false
    private let size = 4
    private let maxAge: TimeInterval = 120

    func warmUp(engine: TelegramProxyEngine) {
        for dc in TelegramProxyEngine.webSocketAddress.keys {
            for media in [false, true] { refill(Key(dc: dc, isMedia: media), engine: engine) }
        }
    }

    /// A ready connection, or a new one made right now; nil if the gateway cannot be reached.
    func take(dc: Int, isMedia: Bool, engine: TelegramProxyEngine) async -> WebSocketClient? {
        guard let address = TelegramProxyEngine.webSocketAddress[dc] else { return nil }
        let key = Key(dc: dc, isMedia: isMedia)
        while var list = idle[key], !list.isEmpty {
            let candidate = list.removeFirst()
            idle[key] = list
            if candidate.looksUsable, Date().timeIntervalSince(candidate.createdAt) < maxAge {
                refill(key, engine: engine)
                return candidate
            }
            candidate.close()
        }
        refill(key, engine: engine)
        return await connectOne(address: address, domains: TelegramProxyEngine.webSocketDomains(dc: dc, isMedia: isMedia))
    }

    private func refill(_ key: Key, engine: TelegramProxyEngine) {
        guard !refilling.contains(key), (retryAfter[key] ?? .distantPast) <= Date(),
              let address = TelegramProxyEngine.webSocketAddress[key.dc], engine.isRunning else { return }
        refilling.insert(key)
        Task {
            await self.fill(key, address: address, engine: engine)
        }
    }

    private func fill(_ key: Key, address: String, engine: TelegramProxyEngine) async {
        defer { refilling.remove(key) }
        idle[key] = (idle[key] ?? []).filter { $0.looksUsable && Date().timeIntervalSince($0.createdAt) < maxAge }
        let needed = size - (idle[key]?.count ?? 0)
        guard needed > 0 else { return }
        let domains = TelegramProxyEngine.webSocketDomains(dc: key.dc, isMedia: key.isMedia)
        var made = 0
        for _ in 0..<needed {
            guard engine.isRunning, let ws = await connectOne(address: address, domains: domains) else { break }
            idle[key, default: []].append(ws)
            made += 1
        }
        if made > 0 { failures[key] = nil; retryAfter[key] = nil }
        else {
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            retryAfter[key] = Date().addingTimeInterval(min(pow(2, Double(min(count - 1, 12))), 3600))
        }
    }

    private func connectOne(address: String, domains: [String]) async -> WebSocketClient? {
        for domain in domains {
            for fronted in tryFrontingFirst ? [true, false] : [false, true] {
                if let ws = try? await WebSocketClient.connect(address: address, domain: domain, sni: fronted ? "sprinthost.ru" : nil, timeout: fronted ? 7 : 8) {
                    tryFrontingFirst = fronted
                    return ws
                }
            }
        }
        return nil
    }

    func closeAll() {
        for list in idle.values { list.forEach { $0.close() } }
        idle.removeAll()
        retryAfter.removeAll()
        failures.removeAll()
    }
}

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ChannelError("время ожидания истекло")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
