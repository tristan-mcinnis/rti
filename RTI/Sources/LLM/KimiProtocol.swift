import Foundation

struct KimiMessage: Codable {
    let role: String   // "system" | "user" | "assistant"
    let content: String
}

struct KimiRequest: Codable {
    let model: String
    let messages: [KimiMessage]
    let stream: Bool
    let temperature: Double?
    let thinking: Thinking?

    struct Thinking: Codable {
        let type: String   // "enabled" | "disabled"
    }
}

struct KimiChatChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta?
        let finish_reason: String?
    }

    struct Delta: Decodable {
        let content: String?
        let role: String?
        // Smart mode (kimi-k2.6) streams thinking output via reasoning_content.
        // We don't display it, but decoding it explicitly stops the stream
        // parser from logging a decode error on every reasoning chunk.
        let reasoning_content: String?
    }
}
