import Foundation
import Network
import Testing
@testable import Nimb

/// A local peer that accepts TCP and then stays silent. A fallback closes the test connection after two seconds, so the old broken
/// timeout fails an assertion rather than hanging the entire test run. No external service or administrator privilege is involved.
@Suite struct ChannelTimeoutTests {
    @Test(arguments: [-1.0, 0.0, -.infinity, .infinity, .nan, .greatestFiniteMagnitude])
    func anExpiredOrInvalidDeadlineDoesNotStartWork(seconds: TimeInterval) async {
        do {
            let _: Int = try await withTimeout(seconds) {
                Issue.record("An expired or invalid deadline must reject before starting work")
                return 1
            }
            Issue.record("An expired or invalid deadline must fail")
        } catch let error as ChannelError {
            #expect(error.message == "время ожидания истекло")
        } catch {
            Issue.record("An invalid deadline returned an unexpected error: \(error)")
        }
    }

    @Test(arguments: [0, 8])
    func aSilentOrPartialHandshakeTimesOut(bytes: Int) async throws {
        let peer = try await SilentLocalPeer.open(initialBytes: Data(repeating: 7, count: bytes))
        defer { peer.close() }
        let client = try await Channel.openTCP(address: "127.0.0.1", port: peer.port, timeout: 1)
        defer { client.cancel() }
        let fallback = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { client.cancel() } }
        defer { fallback.cancel() }
        let start = Date()
        do {
            _ = try await withTimeout(0.1) { try await client.receiveExactly(64) }
            Issue.record("A peer that never finishes its handshake must time out")
        } catch {}
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func cancellingAPendingReadReturnsPromptly() async throws {
        let peer = try await SilentLocalPeer.open()
        defer { peer.close() }
        let client = try await Channel.openTCP(address: "127.0.0.1", port: peer.port, timeout: 1)
        defer { client.cancel() }
        let read = Task { try await client.receiveExactly(64) }
        let fallback = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { client.cancel() } }
        defer { fallback.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        read.cancel()
        if case .success = await read.result { Issue.record("A cancelled pending read must fail") }
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func aSuccessfulReadKeepsTheConnectionUsable() async throws {
        let peer = try await SilentLocalPeer.open(initialBytes: Data(repeating: 9, count: 128))
        defer { peer.close() }
        let client = try await Channel.openTCP(address: "127.0.0.1", port: peer.port, timeout: 1)
        defer { client.cancel() }
        let first = try await withTimeout(1) { try await client.receiveExactly(64) }
        let second = try await withTimeout(1) { try await client.receiveExactly(64) }
        #expect(first == Data(repeating: 9, count: 64))
        #expect(second == first)
    }
}

private final class SilentLocalPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "nimb.tests.silent-peer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var port: UInt16 { listener.port!.rawValue }

    private init(initialBytes: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            if !initialBytes.isEmpty { connection.send(content: initialBytes, completion: .contentProcessed { _ in }) }
        }
    }

    static func open(initialBytes: Data = Data()) async throws -> SilentLocalPeer {
        let peer = try SilentLocalPeer(initialBytes: initialBytes)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            peer.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once { continuation.resume() }
                case .failed(let error): once { continuation.resume(throwing: error) }
                case .cancelled: once { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            peer.listener.start(queue: peer.queue)
        }
        peer.listener.stateUpdateHandler = nil
        return peer
    }

    func close() {
        listener.cancel()
        lock.lock(); let open = connections; connections = []; lock.unlock()
        open.forEach { $0.cancel() }
    }
}
