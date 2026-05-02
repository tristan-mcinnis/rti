import Foundation

enum DeepSeekError: Error {
    case httpError(Int, String)
    case unauthorized
    case badResponse
    case missingAPIKey
    case streamError(String)
}

extension DeepSeekError {
    /// User-facing copy. Single source of truth so all four DeepSeek-using
    /// controllers (LLMController, SummaryController, SessionTitleController,
    /// SessionQAController) surface consistent messages instead of three of
    /// them showing raw `\(error)` output.
    var userMessage: String {
        switch self {
        case .unauthorized:
            return "DeepSeek rejected the API key (401). Open Settings to paste a valid key."
        case .missingAPIKey:
            return "No DeepSeek API key set. Open Settings to add one."
        case .httpError(let code, let body):
            return "DeepSeek error \(code): \(body.prefix(300))"
        case .streamError(let detail):
            return "DeepSeek stream error: \(detail.prefix(300))"
        case .badResponse:
            return "DeepSeek returned an unexpected response."
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
