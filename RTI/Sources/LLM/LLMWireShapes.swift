import Foundation

/// JSON wire shapes for OpenAI-compatible streaming chat completions.
/// Internal to the LLM client; callers should compose requests with
/// `LLMMessage` and consume deltas from `LLMClient.streamChat`.

struct LLMMessage: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

struct LLMWireRequest: Codable {
    let model: String
    let messages: [LLMMessage]
    let stream: Bool
    let temperature: Double?
    let thinking: Thinking?

    /// DeepSeek-style reasoning toggle. Only sent when the active
    /// provider reports `supportsThinking=true`. `type` is "enabled" or
    /// "disabled".
    struct Thinking: Codable {
        let type: String
    }
}

struct LLMStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta?
        let finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
        let role: String?
        /// DeepSeek smart-mode streams reasoning here. Decoding the field
        /// explicitly stops the parser from logging a decode error on
        /// every reasoning chunk.
        let reasoning_content: String?
    }
}
