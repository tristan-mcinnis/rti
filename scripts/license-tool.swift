#!/usr/bin/env swift
// RTI beta-license CLI.
//
//   swift Scripts/license-tool.swift keygen
//       → writes Scripts/license-private.key, prints PUBLIC_KEY_BASE64
//         to paste into RTI/Sources/Settings/LicenseStore.swift.
//
//   swift Scripts/license-tool.swift sign <email> [days]
//       → emits a single RTI-… key valid for `days` (default 60),
//         signed with Scripts/license-private.key.
//
//   swift Scripts/license-tool.swift verify <key>
//       → prints decoded payload + verifies signature against the
//         private key's derived public key.
//
// Keep `Scripts/license-private.key` out of git. There is no recovery
// if it is lost — every beta key already shipped becomes the only proof
// the system was ever signed.

import Foundation
import CryptoKit

let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let keyPath = (scriptDir as NSString).appendingPathComponent("license-private.key")

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

func base64URL(_ d: Data) -> String {
    d.base64EncodedString()
     .replacingOccurrences(of: "+", with: "-")
     .replacingOccurrences(of: "/", with: "_")
     .replacingOccurrences(of: "=", with: "")
}
func base64URLDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    t += String(repeating: "=", count: (4 - t.count % 4) % 4)
    return Data(base64Encoded: t)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard FileManager.default.fileExists(atPath: keyPath) else {
        die("private key not found at \(keyPath) — run `license-tool.swift keygen` first")
    }
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: keyPath)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        die("could not read private key at \(keyPath)")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    die("usage: license-tool.swift {keygen|sign <email> [days]|verify <key>}")
}

switch cmd {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath) {
        die("refuse to overwrite existing private key at \(keyPath)")
    }
    let priv = Curve25519.Signing.PrivateKey()
    try priv.rawRepresentation.write(to: URL(fileURLWithPath: keyPath))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    let pub = priv.publicKey.rawRepresentation.base64EncodedString()
    print("Wrote private key → \(keyPath)")
    print("")
    print("Paste this into LicenseStore.swift `publicKeyBase64`:")
    print("    \(pub)")

case "sign":
    guard args.count >= 2 else { die("usage: sign <email> [days]") }
    let email = args[1]
    let days = args.count >= 3 ? (Int(args[2]) ?? 60) : 60
    let priv = loadPrivateKey()
    let issued = Int(Date().timeIntervalSince1970)
    let payload: [String: Any] = ["s": email, "i": issued, "d": days]
    let payloadData = try JSONSerialization.data(
        withJSONObject: payload, options: [.sortedKeys]
    )
    let sig = try priv.signature(for: payloadData)
    let key = "RTI-\(base64URL(payloadData)).\(base64URL(sig))"
    let exp = Date(timeIntervalSince1970: TimeInterval(issued + days * 86_400))
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
    FileHandle.standardError.write(Data("subject: \(email)\nissued:  \(f.string(from: Date()))\nexpires: \(f.string(from: exp))  (\(days)d)\n\n".utf8))
    print(key)

case "verify":
    guard args.count >= 2 else { die("usage: verify <key>") }
    let raw = args[1]
    guard raw.hasPrefix("RTI-") else { die("malformed: missing RTI- prefix") }
    let body = String(raw.dropFirst(4))
    let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          let payloadData = base64URLDecode(parts[0]),
          let sig = base64URLDecode(parts[1])
    else { die("malformed: not two base64url parts") }
    let pub = loadPrivateKey().publicKey
    guard pub.isValidSignature(sig, for: payloadData) else { die("bad signature") }
    let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] ?? [:]
    print("ok")
    print(payload)

default:
    die("unknown command: \(cmd)")
}
