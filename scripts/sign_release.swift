#!/usr/bin/env swift
// Signs the zip of a release, so that Nimb installs only updates that its maker made (the hash in the notes of a release lives in the same
// place as the zip: whoever can change the one can change the other, and a signature cannot be made without the private key).
//
//   swift scripts/sign_release.swift generate        makes the key (once) in ~/.config/nimb/release-signing.key and prints the public key
//   swift scripts/sign_release.swift public          prints the public key (it is built into Updater.trustedKeys)
//   swift scripts/sign_release.swift sign <file>     writes <file>.sig (put it among the files of the release)
//
// The private key never goes into the repository. Keep a copy of it somewhere safe and off the net: without it no update can be signed.
import CryptoKit
import Foundation

let keyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/nimb/release-signing.key")

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("No key at \(keyPath): run `generate` first.\n".utf8))
        exit(1)
    }
    return key
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) {
        FileHandle.standardError.write(Data("A key is already at \(keyPath): it is not replaced.\n".utf8))
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    let folder = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count > 2, let data = FileManager.default.contents(atPath: arguments[2]) else {
        FileHandle.standardError.write(Data("Usage: sign <file>\n".utf8))
        exit(1)
    }
    let signature = try loadKey().signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: arguments[2] + ".sig"))
    print("\(arguments[2]).sig")
default:
    FileHandle.standardError.write(Data("Usage: generate | public | sign <file>\n".utf8))
    exit(1)
}
