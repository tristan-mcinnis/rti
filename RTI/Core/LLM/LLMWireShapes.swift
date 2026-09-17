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
    /// Images sent with this message. Providers accept images in USER messages
    /// only, so the turn attaches them to the latest user message. Encoded as
    /// OpenAI `content` blocks (a `text` block plus one `image_url` per image)
    /// instead of a plain string.
    public let images: [LLMImage]?

    enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, name
    }

    public init(
        role: String,
        content: String? = nil,
        tool_calls: [LLMToolCall]? = nil,
        tool_call_id: String? = nil,
        name: String? = nil,
        images: [LLMImage]? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
        self.images = images
    }

    /// The block shapes for a multimodal message. Written by hand so a plain
    /// text message still goes out as a bare string (every other provider and
    /// the tool paths depend on that shape).
    private enum BlockKeys: String, CodingKey {
        case type, text, image_url
    }

    private struct ImageURLBox: Encodable {
        let url: String
    }

    private enum Block: Encodable {
        case text(String)
        case imageURL(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: BlockKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .imageURL(url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURLBox(url: url), forKey: .image_url)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let images, !images.isEmpty {
            var blocks: [Block] = []
            if let content, !content.isEmpty { blocks.append(.text(content)) }
            blocks.append(contentsOf: images.map { .imageURL($0.dataURL) })
            try container.encode(blocks, forKey: .content)
        } else if let content {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        try container.encodeIfPresent(name, forKey: .name)
    }

    /// Only ever used for request bodies this app sends, so the image field is
    /// not decoded back; content is read as a plain string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        tool_calls = try container.decodeIfPresent([LLMToolCall].self, forKey: .tool_calls)
        tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        images = nil
    }
}

/// One image carried with a user message: an OpenAI-compatible `image_url`
/// block with an inline base64 `data:` URL. DeepSeek's `deepseek-flash` and the
/// OpenAI-compatible providers all accept this shape.
public struct LLMImage: Codable, Sendable, Equatable {
    public let jpegData: Data
    public let mimeType: String

    public init(jpegData: Data, mimeType: String = "image/jpeg") {
        self.jpegData = jpegData
        self.mimeType = mimeType
    }

    /// `data:image/jpeg;base64,…`
    public var dataURL: String {
        "data:\(mimeType);base64,\(jpegData.base64EncodedString())"
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
