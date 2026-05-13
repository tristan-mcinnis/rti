import Foundation
import CryptoKit

/// Offline beta-license check. Keys are Ed25519-signed payloads that encode an
/// issue date and a validity window in days. The public key below is embedded
/// at build time; the matching private key lives on the maintainer's machine
/// (`Scripts/license-private.key`, gitignored) and is used by
/// `Scripts/license-tool.swift sign` to mint per-tester keys.
///
/// Threat model: this is beta gating, not DRM. A determined user can patch
/// the binary or roll the clock. We mitigate the easy attacks:
///   - signed payload → can't forge keys without the private key
///   - anti-rollback   → we record the highest wall-clock time we've ever seen
///                       and reject `now` values below that
///   - first-seen lock → expiry is min(payload.issued + days, firstSeen + days)
///                       so re-pasting an old key after expiry doesn't reset
struct License: Codable, Equatable {
    let subject: String     // freeform — typically an email
    let issuedAt: Int       // epoch seconds
    let days: Int           // validity window
    let raw: String         // the full pasted key, for display + replay

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(issuedAt + days * 86_400)) }
    var issuedDate: Date { Date(timeIntervalSince1970: TimeInterval(issuedAt)) }
}

enum LicenseError: Error, LocalizedError {
    case malformed
    case badSignature
    case expired(Date)
    case clockRolledBack
    case notYetValid

    var errorDescription: String? {
        switch self {
        case .malformed: return "Key is not in the expected RTI-… format."
        case .badSignature: return "Key signature is invalid. Make sure you copied the whole key."
        case .expired(let d):
            let f = DateFormatter(); f.dateStyle = .medium
            return "This key expired on \(f.string(from: d))."
        case .clockRolledBack: return "System clock appears to have been moved backwards."
        case .notYetValid: return "Key is dated in the future. Check your system clock."
        }
    }
}

@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    // -------------------------------------------------------------------------
    // Public key — paste the output of `swift Scripts/license-tool.swift keygen`
    // here (base64, 32 bytes / 44 chars). Until replaced this is a placeholder
    // and no key will validate.
    private static let publicKeyBase64 = "cN4NFM38yxrPzyFlYg8pY7uh7upoEpFTnjaAF+fO0UE="
    // -------------------------------------------------------------------------

    private let licenseAccount = "license.key"
    private let firstSeenAccount = "license.firstSeen"
    private let monotonicAccount = "license.monotonic"

    @Published private(set) var current: License?
    @Published private(set) var lastError: LicenseError?

    private init() {
        bumpMonotonic()
        current = try? loadStoredAndVerify()
    }

    // MARK: - Public API

    var isValid: Bool { current != nil }

    /// Validate a freshly-pasted key. On success it is persisted to the
    /// credentials store and becomes `current`.
    @discardableResult
    func install(_ key: String) throws -> License {
        let lic = try Self.parseAndVerify(key)
        let now = Date().timeIntervalSince1970
        if Double(lic.issuedAt) > now + 86_400 { throw LicenseError.notYetValid }
        try enforceWindow(lic, now: now)
        KeychainStore.set(key, for: licenseAccount)
        if KeychainStore.get(firstSeenAccount) == nil {
            KeychainStore.set(String(Int(now)), for: firstSeenAccount)
        }
        current = lic
        lastError = nil
        return lic
    }

    func clear() {
        KeychainStore.delete(licenseAccount)
        current = nil
    }

    /// Re-checks the active license — used by the gate to detect expiry
    /// without an app restart.
    func recheck() {
        current = try? loadStoredAndVerify()
    }

    // MARK: - Internals

    private func loadStoredAndVerify() throws -> License {
        guard let raw = KeychainStore.get(licenseAccount) else { throw LicenseError.malformed }
        let lic = try Self.parseAndVerify(raw)
        let now = Date().timeIntervalSince1970
        try enforceWindow(lic, now: now)
        return lic
    }

    /// Combined window check: payload-expiry AND first-seen-expiry AND
    /// monotonic-clock check. Whichever bound is tighter wins.
    private func enforceWindow(_ lic: License, now: TimeInterval) throws {
        // Anti-rollback: never accept a wall clock earlier than the highest
        // we've persisted (minus a 60s slop for legitimate NTP corrections).
        if let m = KeychainStore.get(monotonicAccount), let mv = TimeInterval(m), now + 60 < mv {
            throw LicenseError.clockRolledBack
        }

        let payloadExpiry = TimeInterval(lic.issuedAt + lic.days * 86_400)
        let firstSeen = TimeInterval(KeychainStore.get(firstSeenAccount).flatMap { Int($0) } ?? lic.issuedAt)
        let firstSeenExpiry = firstSeen + TimeInterval(lic.days * 86_400)
        let effective = min(payloadExpiry, firstSeenExpiry)

        if now >= effective {
            throw LicenseError.expired(Date(timeIntervalSince1970: effective))
        }
    }

    private func bumpMonotonic() {
        let now = Int(Date().timeIntervalSince1970)
        let prev = Int(KeychainStore.get(monotonicAccount) ?? "0") ?? 0
        if now > prev { KeychainStore.set(String(now), for: monotonicAccount) }
    }

    // MARK: - Parse + verify

    /// Key format: `RTI-<base64url(payloadJSON)>.<base64url(signature)>`
    /// payloadJSON: `{"s":"email","i":1700000000,"d":60}`
    static func parseAndVerify(_ key: String) throws -> License {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("RTI-") else { throw LicenseError.malformed }
        let body = String(trimmed.dropFirst(4))
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64URLEncoded: String(parts[0])),
              let sigData = Data(base64URLEncoded: String(parts[1]))
        else { throw LicenseError.malformed }

        guard let pubData = Data(base64Encoded: publicKeyBase64),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
            throw LicenseError.malformed
        }

        guard pubKey.isValidSignature(sigData, for: payloadData) else {
            throw LicenseError.badSignature
        }

        struct Payload: Decodable { let s: String; let i: Int; let d: Int }
        let p = try JSONDecoder().decode(Payload.self, from: payloadData)
        return License(subject: p.s, issuedAt: p.i, days: p.d, raw: trimmed)
    }
}

// MARK: - base64url

extension Data {
    init?(base64URLEncoded s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        t += String(repeating: "=", count: pad)
        guard let d = Data(base64Encoded: t) else { return nil }
        self = d
    }
}
