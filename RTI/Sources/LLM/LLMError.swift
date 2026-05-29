import Foundation

enum LLMError: Error {
    case httpError(Int, String)
    case unauthorized
    case badResponse
    case missingAPIKey
    case streamError(String)
}

extension LLMError {
    /// User-facing copy. Single source of truth so every LLM-using
    /// controller surfaces consistent messages instead of showing raw
    /// `\(error)` output.
    var userMessage: String {
        switch self {
        case .unauthorized:
            return "LLM provider rejected the API key (401). Open Settings to paste a valid key."
        case .missingAPIKey:
            return "No LLM API key set. Open Settings to add one."
        case .httpError(let code, let body):
            return "LLM error \(code): \(body.prefix(300))"
        case .streamError(let detail):
            return "LLM stream error: \(detail.prefix(300))"
        case .badResponse:
            return "LLM provider returned an unexpected response."
        }
    }

    /// `true` for the two error modes the UI uses to gate the "Open Settings"
    /// affordance (missing or rejected key).
    var isAuth: Bool {
        switch self {
        case .unauthorized, .missingAPIKey:
            return true
        case .httpError, .streamError, .badResponse:
            return false
        }
    }
}
