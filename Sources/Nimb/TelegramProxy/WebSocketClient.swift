import Foundation

struct WebSocketHandshakeError: LocalizedError {
    let statusLine: String
    let location: String?
    var errorDescription: String? { statusLine }
}

/// A minimal WebSocket client for Telegram's `/apiws` gateway: binary frames only, masked on the way out.
final class WebSocketClient: @unchecked Sendable {
    private let channel: Channel
    private var buffer = Data()
    private var fragments = Data()
    private(set) var isClosed = false
    let createdAt = Date()

    private init(channel: Channel) { self.channel = channel }

    /// Connects to `address`, asks for the WebSocket upgrade with `Host: domain`, and checks for status 101.
    /// `sni` other than the domain is the "fronting" variant: the certificate is then not checked.
    static func connect(address: String, domain: String, path: String = "/apiws", sni: String? = nil, timeout: TimeInterval = 8) async throws -> WebSocketClient {
        let channel = try await Channel.openTLS(address: address, serverName: sni ?? domain, verify: sni == nil, timeout: timeout)
        do {
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let request = "GET \(path) HTTP/1.1\r\nHost: \(domain)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
            try await channel.send(Data(request.utf8))

            var head = Data()
            let terminator = Data("\r\n\r\n".utf8)
            let deadline = Date().addingTimeInterval(timeout)
            while head.range(of: terminator) == nil {
                guard Date() < deadline, head.count < 16384 else { throw ChannelError("ответ на рукопожатие слишком долгий") }
                guard let chunk = try await channel.receive(maximum: 4096) else { throw ChannelError("соединение закрыто при рукопожатии") }
                head.append(chunk)
            }
            let end = head.range(of: terminator)!
            let lines = String(decoding: head[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let statusLine = lines.first ?? ""
            let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
            guard status == 101 else {
                let location = lines.dropFirst().first { $0.lowercased().hasPrefix("location:") }
                    .map { String($0.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces) }
                throw WebSocketHandshakeError(statusLine: statusLine, location: location)
            }
            let client = WebSocketClient(channel: channel)
            client.buffer = Data(head[end.upperBound...])
            return client
        } catch {
            channel.cancel()
            throw error
        }
    }

    func send(_ payload: Data) async throws {
        guard !isClosed else { throw ChannelError("WebSocket закрыт") }
        try await channel.send(Self.frame(opcode: 0x2, payload: payload))
    }

    func sendBatch(_ parts: [Data]) async throws {
        guard !isClosed else { throw ChannelError("WebSocket закрыт") }
        var all = Data()
        for part in parts { all.append(Self.frame(opcode: 0x2, payload: part)) }
        try await channel.send(all)
    }

    /// The next whole message from the server, or nil once it has closed the connection.
    func receive() async throws -> Data? {
        while !isClosed {
            let (opcode, payload, fin) = try await readFrame()
            switch opcode {
            case 0x8:
                isClosed = true
                try? await channel.send(Self.frame(opcode: 0x8, payload: payload.prefix(2)))
                return nil
            case 0x9:
                try? await channel.send(Self.frame(opcode: 0xA, payload: payload))
            case 0xA:
                continue
            default:
                if fin && fragments.isEmpty { return payload }
                fragments.append(payload)
                if fragments.count > 16 * 1024 * 1024 { throw ChannelError("сообщение WebSocket слишком большое") }
                if fin {
                    defer { fragments = Data() }
                    return fragments
                }
            }
        }
        return nil
    }

    func close() {
        guard !isClosed else { channel.cancel(); return }
        isClosed = true
        let channel = channel
        Task {
            try? await channel.send(Self.frame(opcode: 0x8, payload: Data()))
            channel.cancel()
        }
    }

    var looksUsable: Bool { !isClosed && !channel.isClosed }

    // MARK: Framing

    static func frame(opcode: UInt8, payload: Data) -> Data {
        var header = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 { header.append(0x80 | UInt8(length)) }
        else if length < 65536 { header.append(0x80 | 126); header.append(UInt8(length >> 8)); header.append(UInt8(length & 0xff)) }
        else {
            header.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xff)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        header.append(contentsOf: mask)
        var masked = Data(payload)
        masked.withUnsafeMutableBytes { bytes in
            let b = bytes.bindMemory(to: UInt8.self)
            for i in 0..<b.count { b[i] ^= mask[i & 3] }
        }
        return header + masked
    }

    private func readFrame() async throws -> (UInt8, Data, Bool) {
        let head = try await take(2)
        let fin = head[head.startIndex] & 0x80 != 0
        let opcode = head[head.startIndex] & 0x0f
        let masked = head[head.startIndex + 1] & 0x80 != 0
        var length = Int(head[head.startIndex + 1] & 0x7f)
        if length == 126 {
            let b = try await take(2)
            length = Int(b[b.startIndex]) << 8 | Int(b[b.startIndex + 1])
        } else if length == 127 {
            let b = try await take(8)
            var value: UInt64 = 0
            for byte in b { value = value << 8 | UInt64(byte) }
            guard value <= 16 * 1024 * 1024 else { throw ChannelError("кадр WebSocket слишком большой") }
            length = Int(value)
        }
        var mask = Data()
        if masked { mask = try await take(4) }
        var payload = try await take(length)
        if masked {
            payload.withUnsafeMutableBytes { bytes in
                let b = bytes.bindMemory(to: UInt8.self)
                for i in 0..<b.count { b[i] ^= mask[mask.startIndex + (i & 3)] }
            }
        }
        return (opcode, payload, fin)
    }

    private func take(_ count: Int) async throws -> Data {
        while buffer.count < count {
            guard let chunk = try await channel.receive() else { throw ChannelError("соединение закрыто") }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }
}
