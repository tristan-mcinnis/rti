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
    }
}
