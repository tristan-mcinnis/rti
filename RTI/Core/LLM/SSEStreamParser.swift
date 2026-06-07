import Foundation

/// Pure parser for an OpenAI-compatible chat-completions SSE stream. Feed it
/// raw lines one at a time; it returns the events each line produced and
/// accumulates streaming tool-call fragments + the finish reason internally.
/// Extracted from `LLMClient` so the parsing — the part where bugs hide — is
/// unit-testable without a live network stream.
public struct SSEStreamParser {
    public enum Event: Equatable {
        /// A `delta.content` fragment.
        case content(String)
        /// A `delta.reasoning_content` fragment (DeepSeek smart mode).
        case reasoning(String)
        /// The `data: [DONE]` sentinel — the caller should stop reading.
        case done
        /// A mid-stream `{"error": …}` object — the caller should fail.
        case streamError(String)
    }

    /// Keyed by stream-chunk `index`. Tool-call fragments arrive in sequence:
    /// id+name in the first chunk for an index, then `arguments` deltas
    /// concatenated until the stream ends.
    private var toolBuffer: [Int: (id: String, name: String, args: String)] = [:]
    public private(set) var finishReason: String?

    public init() {}

    /// Process one raw SSE line. A single line can yield both a reasoning and
    /// a content event; tool-call fragments are accumulated internally and
    /// produce no event until assembled. Comment/non-data/undecodable lines
    /// yield no events.
    public mutating func consume(line rawLine: String) -> [Event] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        // Comments per the SSE spec start with a colon.
        if line.hasPrefix(":") { return [] }
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let data = payload.data(using: .utf8) else { return [] }

        // Some servers send {"error": {...}} mid-stream instead of [DONE].
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"]
        {
            let detail: String = {
                if let msg = err as? [String: Any], let text = msg["message"] as? String { return text }
                return "\(err)"
            }()
            return [.streamError(detail)]
        }

        guard let chunk = try? JSONDecoder().decode(LLMStreamChunk.self, from: data),
              let choice = chunk.choices.first else { return [] }

        var events: [Event] = []
        if let reason = choice.finish_reason { finishReason = reason }
        if let reasoning = choice.delta?.reasoning_content, !reasoning.isEmpty {
            events.append(.reasoning(reasoning))
        }
        if let content = choice.delta?.content, !content.isEmpty {
            events.append(.content(content))
        }
        if let tcs = choice.delta?.tool_calls {
            for tc in tcs {
                var entry = toolBuffer[tc.index] ?? (id: "", name: "", args: "")
                if let id = tc.id, !id.isEmpty { entry.id = id }
                if let name = tc.function?.name, !name.isEmpty { entry.name = name }
                if let args = tc.function?.arguments { entry.args += args }
                toolBuffer[tc.index] = entry
            }
        }
        return events
    }

    /// Assemble the accumulated tool calls once the stream has ended. Ordered
    /// by chunk index; fragments missing an id or name are dropped.
    public func assembledToolCalls() -> [LLMToolCall] {
        toolBuffer
            .sorted { $0.key < $1.key }
            .compactMap { _, v in
                guard !v.id.isEmpty, !v.name.isEmpty else { return nil }
                return LLMToolCall(
                    id: v.id,
                    type: "function",
                    function: .init(name: v.name, arguments: v.args)
                )
            }
    }
}
