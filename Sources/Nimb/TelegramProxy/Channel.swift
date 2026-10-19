import Foundation
import Network

/// Runs a block the first time it is called and ignores later calls (a continuation may be resumed only once).
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func callAsFunction(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

struct ChannelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// An `NWConnection` with async reading and writing. A read that returns nil is the end of the stream.
final class Channel: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "nimb.telegram.channel")

    init(connection: NWConnection) { self.connection = connection }

    /// Connects to `address:443` over TLS. `serverName` is sent as SNI; with `verify` false any certificate is accepted
    /// (needed only when the SNI is not the real host name).
    static func openTLS(address: String, port: UInt16 = 443, serverName: String, verify: Bool, timeout: TimeInterval) async throws -> Channel {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        if !verify {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, DispatchQueue(label: "nimb.telegram.verify"))
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let channel = Channel(connection: connection)
        try await channel.start(timeout: timeout)
        return channel
    }

    static func openTCP(address: String, port: UInt16, timeout: TimeInterval) async throws -> Channel {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        let channel = Channel(connection: connection)
        try await channel.start(timeout: timeout)
        return channel
    }

    /// Waits until the connection is ready. An accepted connection is already running, so this only waits.
    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            @Sendable func finish(_ result: Result<Void, Error>) {
                once { continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(ChannelError("соединение закрыто")))
                case .waiting(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(ChannelError("время ожидания истекло")))
            }
        }
        connection.stateUpdateHandler = nil
    }

    /// Reads up to `maximum` bytes (at least one). nil means the other side has finished.
    func receive(maximum: Int = 65536) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    /// Reads exactly `count` bytes; throws if the stream ends first.
    func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            guard let chunk else { throw ChannelError("соединение закрыто") }
            result.append(chunk)
        }
        return result
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func cancel() { connection.cancel() }

    var isClosed: Bool {
        switch connection.state {
        case .cancelled, .failed: return true
        default: return false
        }
    }
}
