import Foundation

// JSON wire shapes for OpenAI-compatible streaming chat completions.
// Callers compose requests with `LLMMessage` and consume deltas from the
// client's stream; the request/chunk shapes are the on-the-wire encoding.

public struct LLMMessage: Codable, Sendable {
    public let role: String // "system" | "user" | "assistant" | "tool"
    public let content: String?
    /// Assistant-only: function tool calls the model wants the host to run.
    public let tool_calls: [LLMToolCall]?
    /// Tool-only: the id of the tool_call this message satisfies.
    public let tool_call_id: String?
    /// Tool-only: the function name (mirrors tool_call_id for clarity).
    public let name: String?

    public init(
        role: String,
        content: String? = nil,
        tool_calls: [LLMToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

/// A single function tool call emitted by the assistant. `arguments` is a
/// JSON-encoded string per the OpenAI tool-call spec.
public struct LLMToolCall: Codable, Sendable {
    public let id: String
    public let type: String // always "function" for now
    public let function: Function

    public struct Function: Codable, Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public init(id: String, type: String, function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct LLMWireRequest: Codable, Sendable {
    public let model: String
    public let messages: [LLMMessage]
    public let stream: Bool
    public let temperature: Double?
    public let max_tokens: Int?
    public let thinking: Thinking?

    /// DeepSeek-style reasoning toggle. Only sent when the active
    /// provider reports `supportsThinking=true`. `type` is "enabled" or
    /// "disabled".
    public struct Thinking: Codable, Sendable {
        public let type: String

        public init(type: String) {
            self.type = type
        }
    }

    public init(
        model: String,
        messages: [LLMMessage],
        stream: Bool,
        temperature: Double?,
        max_tokens: Int?,
        thinking: Thinking?
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.thinking = thinking
    }
}

public struct LLMStreamChunk: Decodable, Sendable {
    public let choices: [Choice]

    public struct Choice: Decodable, Sendable {
        public let delta: Delta?
        public let finish_reason: String?
    }

    public struct Delta: Decodable, Sendable {
        public let content: String?
        public let role: String?
        /// DeepSeek smart-mode streams reasoning here. Decoding the field
        /// explicitly stops the parser from logging a decode error on
        /// every reasoning chunk.
        public let reasoning_content: String?
        /// Streaming tool-call fragments. Each entry carries an `index` so
        /// the client can accumulate `arguments` strings across chunks.
        public let tool_calls: [ToolCallDelta]?
    }

    public struct ToolCallDelta: Decodable, Sendable {
        public let index: Int
        public let id: String?
        public let type: String?
        public let function: FunctionDelta?

        public struct FunctionDelta: Decodable, Sendable {
            public let name: String?
            public let arguments: String?
        }
    }
}
