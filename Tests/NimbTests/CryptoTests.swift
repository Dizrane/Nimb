import CryptoKit
import Foundation
import Testing
@testable import Nimb

private func bytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// The ciphers of the Telegram proxy: if AES-CTR is wrong, no Telegram message gets through, and nothing else would show why.
@Suite struct AESCTRTests {
    // NIST SP 800-38A, F.5.5: CTR-AES256.Encrypt
    private let key = bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
    private let iv = bytes("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
    private let plain = bytes("6bc1bee22e409f96e93d7e117393172a" + "ae2d8a571e03ac9c9eb76fac45af8e51")
    private let cipher = bytes("601ec313775789a5b7a7f504bbf3d228" + "f443e3ca4d62b59aca84e990cacaf5c5")

    @Test func matchesTheNISTVector() {
        #expect(AESCTR(key: key, iv: iv).update(plain) == cipher)
    }

    @Test func decryptingIsTheSameOperation() {
        #expect(AESCTR(key: key, iv: iv).update(cipher) == plain)
    }

    @Test func piecesGiveTheSameStreamAsOneCall() {
        let stream = AESCTR(key: key, iv: iv)
        var out = Data()
        for piece in [plain.prefix(5), plain.dropFirst(5).prefix(20), plain.dropFirst(25)] { out += stream.update(Data(piece)) }
        #expect(out == cipher)
    }
}

@Suite struct MTProtoTests {
    private let secret = Data((0..<16).map { UInt8($0 * 7 + 3) })

    /// A header as a client would make it: random, with the protocol tag and the data centre in its encrypted tail.
    private func clientHandshake(secret: Data, tag: Data = MTProto.tagSecure, dcIndex: Int16) -> Data {
        var random = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let prekeyAndIV = random[8..<56]
        let key = Data(SHA256.hash(data: prekeyAndIV.prefix(32) + secret))
        let keystream = AESCTR(key: key, iv: Data(prekeyAndIV.suffix(16))).update(Data(count: 64))
        let tail = tag + withUnsafeBytes(of: dcIndex.littleEndian) { Data($0) } + Data([1, 2])
        for i in 0..<8 { random[56 + i] = tail[i] ^ keystream[56 + i] }
        return random
    }

    @Test func readsTheDataCentreAndTransport() throws {
        let parsed = try #require(MTProto.parse(clientHandshake(secret: secret, dcIndex: 2), secret: secret))
        #expect(parsed.dc == 2)
        #expect(!parsed.isMedia)
        #expect(!parsed.isTestDC)
        #expect(parsed.transport == .paddedIntermediate)
    }

    @Test func aNegativeIndexIsMedia() throws {
        let parsed = try #require(MTProto.parse(clientHandshake(secret: secret, dcIndex: -4), secret: secret))
        #expect(parsed.dc == 4)
        #expect(parsed.isMedia)
    }

    @Test func aTestDataCentreIsRecognised() throws {
        let parsed = try #require(MTProto.parse(clientHandshake(secret: secret, dcIndex: 10003), secret: secret))
        #expect(parsed.dc == 3)
        #expect(parsed.isTestDC)
    }

    @Test func otherTransports() throws {
        let abridged = try #require(MTProto.parse(clientHandshake(secret: secret, tag: MTProto.tagAbridged, dcIndex: 1), secret: secret))
        let intermediate = try #require(MTProto.parse(clientHandshake(secret: secret, tag: MTProto.tagIntermediate, dcIndex: 1), secret: secret))
        #expect(abridged.transport == .abridged)
        #expect(intermediate.transport == .intermediate)
    }

    /// The case the warning «Telegram подключается с чужим ключом» is about.
    @Test func anotherSecretIsRefused() {
        let other = Data((0..<16).map { UInt8($0 * 11 + 5) })
        #expect(MTProto.parse(clientHandshake(secret: other, dcIndex: 2), secret: secret) == nil)
    }

    @Test func noiseAndWrongLengthAreRefused() {
        #expect(MTProto.parse(Data((0..<64).map { _ in UInt8.random(in: 0...255) }), secret: secret) == nil)
        #expect(MTProto.parse(Data(count: 63), secret: secret) == nil)
        #expect(MTProto.parse(Data(count: 65), secret: secret) == nil)
    }

    @Test func theRelayHeaderCarriesTheTagAndTheDataCentre() {
        let relay = MTProto.makeRelayInit(tag: MTProto.tagSecure, dcIndex: 5)
        #expect(relay.count == 64)
        #expect(relay[0] != 0xef)
        let plain = AESCTR(key: relay[8..<40], iv: relay[40..<56]).update(relay)
        #expect(Data(plain[56..<60]) == MTProto.tagSecure)
        #expect(Int16(bitPattern: UInt16(plain[60]) | UInt16(plain[61]) << 8) == 5)
    }
}
