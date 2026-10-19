import CommonCrypto
import CryptoKit
import Foundation

// The Telegram proxy is a Swift port of the relay idea of TG WS Proxy by Flowseal (MIT):
// https://github.com/Flowseal/tg-ws-proxy (see THIRD-PARTY-NOTICES.md).

/// AES-256 in CTR mode, built from the public AES-ECB of CommonCrypto (CommonCrypto has no public CTR).
/// The counter is the usual 128-bit big-endian one, so the stream matches OpenSSL and Python's `cryptography`.
final class AESCTR {
    private var cryptor: CCCryptorRef?
    private var counter: [UInt8]
    private var keystream = [UInt8]()
    private var used = 0

    init(key: Data, iv: Data) {
        precondition(key.count == 32 && iv.count == 16)
        counter = [UInt8](iv)
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, key.count, nil, &ref)
        }
        precondition(status == kCCSuccess, "AES setup failed")
        cryptor = ref
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    /// Encrypts (or, the same thing, decrypts) the next bytes of the stream.
    func update(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let needed = data.count - (keystream.count - used)
        if needed > 0 { extendKeystream(by: needed) }

        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                keystream.withUnsafeBufferPointer { stream in
                    let o = out.bindMemory(to: UInt8.self), i = input.bindMemory(to: UInt8.self)
                    let base = used
                    for index in 0..<i.count { o[index] = i[index] ^ stream[base + index] }
                }
            }
        }
        used += data.count
        if used == keystream.count { keystream.removeAll(keepingCapacity: true); used = 0 }
        return output
    }

    private func extendKeystream(by count: Int) {
        let blocks = (count + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        for block in 0..<blocks {
            counters.replaceSubrange(block * 16..<block * 16 + 16, with: counter)
            increment()
        }
        var encrypted = [UInt8](repeating: 0, count: counters.count)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, counters, counters.count, &encrypted, encrypted.count, &moved)
        precondition(status == kCCSuccess && moved == counters.count, "AES block failed")
        if used > 0 { keystream.removeFirst(used); used = 0 }
        keystream.append(contentsOf: encrypted)
    }

    private func increment() {
        var index = 15
        while index >= 0 {
            counter[index] &+= 1
            if counter[index] != 0 { break }
            index -= 1
        }
    }
}

enum MTProto {
    static let handshakeLength = 64
    static let skip = 8, prekey = 32, ivLength = 16
    static let protoTagPosition = 56, dcIndexPosition = 60

    static let tagAbridged = Data([0xef, 0xef, 0xef, 0xef])
    static let tagIntermediate = Data([0xee, 0xee, 0xee, 0xee])
    static let tagSecure = Data([0xdd, 0xdd, 0xdd, 0xdd])

    enum Transport { case abridged, intermediate, paddedIntermediate }

    struct Handshake {
        let dc: Int
        let isMedia: Bool
        let isTestDC: Bool
        let tag: Data
        let transport: Transport
        /// The 48 bytes after the first 8: key and IV of the client's side.
        let clientPrekeyAndIV: Data
    }

    /// Reads the 64-byte obfuscated2 header the client sends first. Returns nil if the secret or the protocol is wrong.
    static func parse(_ handshake: Data, secret: Data) -> Handshake? {
        guard handshake.count == handshakeLength else { return nil }
        let bytes = [UInt8](handshake)
        let prekeyAndIV = Data(bytes[skip..<skip + prekey + ivLength])
        let key = Data(SHA256.hash(data: prekeyAndIV.prefix(prekey) + secret))
        let decrypted = AESCTR(key: key, iv: prekeyAndIV.suffix(ivLength)).update(handshake)
        let tag = Data(decrypted[protoTagPosition..<protoTagPosition + 4])

        let transport: Transport
        switch tag {
        case tagAbridged: transport = .abridged
        case tagIntermediate: transport = .intermediate
        case tagSecure: transport = .paddedIntermediate
        default: return nil
        }
        let index = Int16(bitPattern: UInt16(decrypted[dcIndexPosition]) | UInt16(decrypted[dcIndexPosition + 1]) << 8)
        var dc = abs(Int(index))
        let isTest = dc >= 10000
        if isTest { dc -= 10000 }
        return Handshake(dc: dc, isMedia: index < 0, isTestDC: isTest, tag: tag, transport: transport, clientPrekeyAndIV: prekeyAndIV)
    }

    /// The 64-byte header this proxy sends to Telegram: random, with the protocol tag and the DC in its encrypted tail.
    static func makeRelayInit(tag: Data, dcIndex: Int) -> Data {
        var random = [UInt8](repeating: 0, count: handshakeLength)
        while true {
            for i in 0..<handshakeLength { random[i] = UInt8.random(in: 0...255) }
            if random[0] == 0xef { continue }
            let start = Data(random[0..<4])
            if [Data([0x48, 0x45, 0x41, 0x44]), Data([0x50, 0x4f, 0x53, 0x54]), Data([0x47, 0x45, 0x54, 0x20]),
                tagIntermediate, tagSecure, Data([0x16, 0x03, 0x01, 0x02]), Data([0x4f, 0x50, 0x54, 0x49])].contains(start) { continue }
            if Data(random[4..<8]) == Data([0, 0, 0, 0]) { continue }
            break
        }
        let plain = Data(random)
        let encryptor = AESCTR(key: plain[skip..<skip + prekey], iv: plain[skip + prekey..<skip + prekey + ivLength])
        let dcBytes = withUnsafeBytes(of: Int16(dcIndex).littleEndian) { Data($0) }
        let tailPlain = tag + dcBytes + Data([UInt8.random(in: 0...255), UInt8.random(in: 0...255)])
        let keystreamTail = zip(encryptor.update(plain)[56..<64], plain[56..<64]).map { $0 ^ $1 }
        var result = plain
        for i in 0..<8 { result[56 + i] = tailPlain[i] ^ keystreamTail[i] }
        return result
    }

    /// The four ciphers that carry a session: the client side (with the secret) and the Telegram side (plain keys).
    struct Ciphers {
        let fromClient: AESCTR
        let toClient: AESCTR
        let toTelegram: AESCTR
        let fromTelegram: AESCTR
    }

    static func makeCiphers(handshake: Handshake, secret: Data, relayInit: Data) -> Ciphers {
        let zero = Data(count: handshakeLength)
        let clientPrekeyAndIV = handshake.clientPrekeyAndIV
        let fromClient = AESCTR(key: Data(SHA256.hash(data: clientPrekeyAndIV.prefix(prekey) + secret)),
                                iv: clientPrekeyAndIV.suffix(ivLength))
        _ = fromClient.update(zero)

        let reversed = Data(clientPrekeyAndIV.reversed())
        let toClient = AESCTR(key: Data(SHA256.hash(data: reversed.prefix(prekey) + secret)), iv: reversed.suffix(ivLength))

        let relayKeyAndIV = relayInit[skip..<skip + prekey + ivLength]
        let toTelegram = AESCTR(key: Data(relayKeyAndIV.prefix(prekey)), iv: Data(relayKeyAndIV.suffix(ivLength)))
        _ = toTelegram.update(zero)
        let relayReversed = Data(relayKeyAndIV.reversed())
        let fromTelegram = AESCTR(key: Data(relayReversed.prefix(32)), iv: Data(relayReversed.suffix(16)))
        return Ciphers(fromClient: fromClient, toClient: toClient, toTelegram: toTelegram, fromTelegram: fromTelegram)
    }
}

/// Cuts the stream into MTProto transport packets, so that each goes to Telegram in a WebSocket frame of its own.
struct MessageSplitter {
    private let transport: MTProto.Transport
    private var cipherBuffer = [UInt8]()
    private var plainBuffer = [UInt8]()
    private var disabled = false

    init(transport: MTProto.Transport) { self.transport = transport }

    mutating func split(cipher: Data, plain: Data) -> [Data] {
        guard !cipher.isEmpty else { return [] }
        if disabled { return [cipher] }
        cipherBuffer.append(contentsOf: cipher)
        plainBuffer.append(contentsOf: plain)

        var parts: [Data] = []
        var offset = 0
        while offset < cipherBuffer.count {
            guard let length = nextLength(at: offset, available: cipherBuffer.count - offset) else { break }
            if length <= 0 {
                parts.append(Data(cipherBuffer[offset...]))
                offset = cipherBuffer.count
                disabled = true
                break
            }
            parts.append(Data(cipherBuffer[offset..<offset + length]))
            offset += length
        }
        if offset > 0 {
            cipherBuffer.removeFirst(offset)
            plainBuffer.removeFirst(offset)
        }
        return parts
    }

    mutating func flush() -> [Data] {
        guard !cipherBuffer.isEmpty else { return [] }
        defer { cipherBuffer.removeAll(); plainBuffer.removeAll() }
        return [Data(cipherBuffer)]
    }

    /// nil: need more bytes; 0 or less: unknown framing, stop splitting.
    private func nextLength(at offset: Int, available: Int) -> Int? {
        guard available > 0 else { return nil }
        switch transport {
        case .abridged:
            let first = plainBuffer[offset]
            let header: Int, payload: Int
            if first == 0x7f || first == 0xff {
                guard available >= 4 else { return nil }
                payload = (Int(plainBuffer[offset + 1]) | Int(plainBuffer[offset + 2]) << 8 | Int(plainBuffer[offset + 3]) << 16) * 4
                header = 4
            } else {
                payload = Int(first & 0x7f) * 4
                header = 1
            }
            if payload <= 0 { return 0 }
            return available >= header + payload ? header + payload : nil
        case .intermediate, .paddedIntermediate:
            guard available >= 4 else { return nil }
            let raw = UInt32(plainBuffer[offset]) | UInt32(plainBuffer[offset + 1]) << 8
                | UInt32(plainBuffer[offset + 2]) << 16 | UInt32(plainBuffer[offset + 3]) << 24
            let payload = Int(raw & 0x7fff_ffff)
            if payload <= 0 { return 0 }
            return available >= 4 + payload ? 4 + payload : nil
        }
    }
}
