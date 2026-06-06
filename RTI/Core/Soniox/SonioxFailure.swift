import Foundation

/// Classified Soniox transcription failure. Pure value type — UI copy and
/// retry policy live as computed properties so they can be unit-tested
/// without mocking a WebSocket.
///
/// Mirrors the `LLMError.userMessage` / `.isAuth` shape so both
/// upstream services surface failures through one mental model.
public enum SonioxFailure: Error, Equatable {
    /// 401 / 402 / 403 — authentication or billing problem. Stop retrying;
    /// surface a Settings affordance so the user can paste a fresh key.
    case auth

    /// 400 — RTI sent a bad request. Stop retrying and log loudly; this is
    /// a client bug, not a transient blip.
    case clientBug(String)

    /// 408 / 429 / 5xx, plus generic network drops, DNS failures, TLS
    /// errors, and post-connect WebSocket drops. Retry with backoff.
    case transient(reason: String)

    /// Anything we don't recognise — retry but log loudly so we can add
    /// a real branch later.
    case unknown(code: Int, body: String)
}

extension SonioxFailure {
    /// Whether `SonioxClient.scheduleReconnect` should attempt another
    /// connection. False for `auth` and `clientBug`; true otherwise.
    public var shouldRetry: Bool {
        switch self {
        case .auth, .clientBug: return false
        case .transient, .unknown: return true
        }
    }

    /// True for the modes the UI uses to gate the "Open Settings"
    /// affordance — same role `LLMError.isAuth` plays.
    public var isAuth: Bool {
        switch self {
        case .auth: return true
        case .clientBug, .transient, .unknown: return false
        }
    }

    /// User-facing copy. Phase-aware — `didOpen=false` means the
    /// connection never opened (handshake / DNS / proxy / firewall), so
    /// the actionable advice is "check internet / proxy." `didOpen=true`
    /// means the session was streaming and dropped, so the message is
    /// "reconnecting" rather than "fix your network."
    public func userMessage(didOpen: Bool) -> String {
        switch self {
        case .auth:
            return "Soniox rejected the API key. Open Settings to update it."
        case .clientBug(let detail):
            return "RTI sent a bad request to Soniox: \(detail.prefix(200))"
        case .transient(let reason):
            if didOpen {
                return "Soniox connection dropped — reconnecting…"
            } else {
                return "Couldn't reach Soniox — check internet connection or proxy settings. (\(reason.prefix(120)))"
            }
        case .unknown(let code, let body):
            return "Soniox error \(code): \(body.prefix(200))"
        }
    }
}

extension SonioxFailure {
    /// Build a failure from a Soniox application-level error message
    /// (these arrive over the WebSocket as JSON `{ "error_code": N, ... }`).
    /// Soniox uses HTTP-style codes here, so the mapping mirrors the
    /// inner-chapter classification.
    public static func fromSonioxApplicationError(code: Int, detail: String) -> SonioxFailure {
        switch code {
        case 400:
            return .clientBug(detail)
        case 401, 402, 403:
            return .auth
        case 408, 429:
            return .transient(reason: "server returned \(code) — \(detail.prefix(120))")
        case 500...599:
            return .transient(reason: "server returned \(code) — \(detail.prefix(120))")
        default:
            return .unknown(code: code, body: detail)
        }
    }

    /// Build a failure from a WebSocket disconnect or transport error.
    /// Most of these are transient — auth-rejection-during-handshake
    /// usually surfaces as a Soniox application error before this fires,
    /// so we lean toward `.transient` here and let the backoff cap stop
    /// us if the failure is permanent.
    public static func fromTransport(reason: String) -> SonioxFailure {
        .transient(reason: reason)
    }
}
