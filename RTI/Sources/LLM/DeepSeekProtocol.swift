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
        // deepseek-reasoner streams thinking output via reasoning_content.
        // We don't display it, but decoding it explicitly stops the stream
        // parser from logging a decode error on every reasoning chunk.
        let reasoning_content: String?
    }
}
