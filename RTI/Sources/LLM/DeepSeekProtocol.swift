import Foundation

struct DeepSeekMessage: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

struct DeepSeekRequest: Codable {
    let model: String
    let messages: [DeepSeekMessage]
    let stream: Bool
    let temperature: Double?
    let thinking: Thinking?

    /// V4 models accept a `thinking` object that toggles reasoning mode.
    /// `type` is "enabled" or "disabled". The legacy aliases deepseek-chat /
    /// deepseek-reasoner correspond to type=disabled / type=enabled on
    /// deepseek-v4-flash respectively.
    struct Thinking: Codable {
        let type: String
    }
}

struct DeepSeekChatChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta?
        let finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
        let role: String?
        // deepseek-v4-flash with thinking enabled streams thinking output
        // via reasoning_content. Decoding it explicitly stops the stream
        // parser from logging a decode error on every reasoning chunk.
        let reasoning_content: String?
    }
}
