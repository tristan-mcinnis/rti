import Foundation

/// JSON wire shapes for OpenAI-compatible streaming chat completions.
/// Internal to the LLM client; callers should compose requests with
/// `LLMMessage` and consume deltas from `LLMClient.streamChat`.

struct LLMMessage: Codable {
    let role: String   // "system" | "user" | "assistant" | "tool"
    let content: String?
    /// Assistant-only: function tool calls the model wants the host to run.
    let tool_calls: [LLMToolCall]?
    /// Tool-only: the id of the tool_call this message satisfies.
    let tool_call_id: String?
    /// Tool-only: the function name (mirrors tool_call_id for clarity).
    let name: String?

    init(role: String,
         content: String? = nil,
         tool_calls: [LLMToolCall]? = nil,
         tool_call_id: String? = nil,
         name: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

/// A single function tool call emitted by the assistant. `arguments` is a
/// JSON-encoded string per the OpenAI tool-call spec.
struct LLMToolCall: Codable {
    let id: String
    let type: String  // always "function" for now
    let function: Function

    struct Function: Codable {
        let name: String
        let arguments: String
    }
}

struct LLMWireRequest: Codable {
    let model: String
    let messages: [LLMMessage]
    let stream: Bool
    let temperature: Double?
    let max_tokens: Int?
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
        /// Streaming tool-call fragments. Each entry carries an `index` so
        /// the client can accumulate `arguments` strings across chunks.
        let tool_calls: [ToolCallDelta]?
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: FunctionDelta?

        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}
