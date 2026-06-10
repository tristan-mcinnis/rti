import Foundation
import RTICore

/// Streaming chat client for any OpenAI-compatible provider.
/// Provider behavior (URL, model, API key, optional `thinking` extension)
/// is supplied via `LLMProviderConfig`; routing to a different LLM is a
/// one-line change in `LLMProviders` rather than edits here.
final class LLMClient: @unchecked Sendable {
    /// Shared instance bound to the active provider. Every LLM-using
    /// controller routes through this. `apiKey` is resolved at call time,
    /// so key edits in Settings take effect on the next request without
    /// rebinding the singleton.
    static let shared = LLMClient(provider: LLMProviders.active)

    let provider: LLMProviderConfig
    private let session: URLSession

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    init(provider: LLMProviderConfig) {
        self.provider = provider
        self.session = Self.sharedSession
    }

    private var apiKey: String { provider.apiKey() }

    // MARK: - Stream result

    /// Output from a single chat-completion stream.
    struct StreamResult {
        let toolCalls: [LLMToolCall]
        let finishReason: String?
    }

    // MARK: - Public streaming API

    /// Streams `delta.content` strings from a chat completion as they
    /// arrive. The stream terminates on `data: [DONE]` sentinel or on
    /// error.
    ///
    /// `smart=true` enables provider-side reasoning when the config
    /// reports `supportsThinking=true`; otherwise it degrades to a normal
    /// completion. `onReasoning`, when supplied, fires on the main thread
    /// for every reasoning_content chunk in smart mode.
    func streamChat(
        messages: [LLMMessage],
        smart: Bool = false,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let temperature: Double? = smart ? nil : 0.6
        let thinking: LLMWireRequest.Thinking? = provider.supportsThinking
            ? LLMWireRequest.Thinking(type: smart ? "enabled" : "disabled")
            : nil
        let timeoutSeconds: Double = smart ? 120 : 60

        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.missingAPIKey) }
        }

        let logDetail = "model=\(provider.model) messages=\(messages.count) smart=\(smart)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(LLMWireRequest(
                        model: provider.model,
                        messages: messages,
                        stream: true,
                        temperature: temperature,
                        max_tokens: 4096,
                        thinking: thinking
                    ))
                    // Plain path yields each delta straight to the stream's
                    // consumer — no main-thread hop (the caller decides).
                    _ = try await performChatStream(
                        httpBody: body,
                        logDetail: logDetail,
                        timeoutSeconds: timeoutSeconds,
                        onContent: { continuation.yield($0) },
                        onReasoning: onReasoning
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streaming chat with OpenAI-style tool support. Yields content deltas
    /// + reasoning via callbacks (so the UI can paint as tokens arrive),
    /// accumulates any tool_calls fragments, and returns the assembled
    /// tool-call list when the stream finishes.
    ///
    /// `toolsJSON` is a pre-built JSON array (see `LLMToolRegistry.wireFormatData()`).
    /// Pass nil to disable tools for this turn.
    func streamChatWithTools(
        messages: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> StreamResult {
        let temperature: Double? = smart ? nil : 0.6
        let timeoutSeconds: Double = smart ? 120 : 60

        var bodyDict: [String: Any] = [
            "model": provider.model,
            "messages": try encodeMessages(messages),
            "stream": true,
            "max_tokens": 4096
        ]
        if let temperature { bodyDict["temperature"] = temperature }
        if provider.supportsThinking {
            bodyDict["thinking"] = ["type": smart ? "enabled" : "disabled"]
        }
        if let toolsJSON,
           let toolsArr = try? JSONSerialization.jsonObject(with: toolsJSON) as? [[String: Any]],
           !toolsArr.isEmpty {
            bodyDict["tools"] = toolsArr
            bodyDict["tool_choice"] = "auto"
        }

        let body = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        let toolCount = (bodyDict["tools"] as? [Any])?.count ?? 0
        // Tools path hops each delta to main — the chat UI paints from it.
        return try await performChatStream(
            httpBody: body,
            logDetail: "tools=\(toolCount) messages=\(messages.count) smart=\(smart)",
            timeoutSeconds: timeoutSeconds,
            onContent: { delta in DispatchQueue.main.async { onContent(delta) } },
            onReasoning: onReasoning
        )
    }

    /// Shared HTTP + streaming scaffolding for both chat paths. Builds the
    /// request from a pre-encoded body, opens the SSE stream, enforces the
    /// per-call timeout, and drives the unified SSE processor. The two public
    /// methods differ only in how they build the body (Encodable vs
    /// tools-augmented dict) and where `onContent` deltas go (the plain path
    /// yields to its AsyncThrowingStream; the tools path hops to main) — both
    /// caller-supplied.
    private func performChatStream(
        httpBody: Data,
        logDetail: String,
        timeoutSeconds: Double,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)?
    ) async throws -> StreamResult {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let providerName = provider.displayName

        var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = httpBody

        RTILog.log("POST provider=\(providerName) \(logDetail)", category: "llm")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        RTILog.log("HTTP \(http.statusCode) provider=\(providerName)", category: "llm")
        guard (200..<300).contains(http.statusCode) else {
            let errText = try await readAll(bytes)
            if http.statusCode == 401 { throw LLMError.unauthorized }
            throw LLMError.httpError(http.statusCode, errText)
        }

        return try await withThrowingTaskGroup(of: StreamResult.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw LLMError.streamError("Stream timed out after \(Int(timeoutSeconds))s")
            }
            group.addTask { [weak self] in
                guard let self else { return StreamResult(toolCalls: [], finishReason: nil) }
                return try await self.processStreamBytes(bytes, onContent: onContent, onReasoning: onReasoning)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Single SSE processor (unified)

    /// Processes SSE bytes from either the plain chat or tool-aware path.
    /// Emits content deltas and reasoning via callbacks. Accumulates any
    /// tool-call fragments and finish_reason. Returns the assembled
    /// `StreamResult` when the stream ends.
    private func processStreamBytes(
        _ bytes: URLSession.AsyncBytes,
        onContent: @Sendable (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)?
    ) async throws -> StreamResult {
        // Parsing lives in RTICore's SSEStreamParser (unit-tested); this loop
        // only drives the byte stream and routes events.
        var parser = SSEStreamParser()
        lines: for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            for event in parser.consume(line: rawLine) {
                switch event {
                case .content(let content):
                    onContent(content)
                case .reasoning(let reasoning):
                    if let onReasoning {
                        DispatchQueue.main.async { onReasoning(reasoning) }
                    }
                case .done:
                    break lines
                case .streamError(let detail):
                    throw LLMError.streamError(detail)
                }
            }
        }
        return StreamResult(toolCalls: parser.assembledToolCalls(), finishReason: parser.finishReason)
    }

    // MARK: - Helpers

    /// Encodes `[LLMMessage]` into the JSON-friendly form used by
    /// `JSONSerialization`. Drops nil fields so the wire body matches
    /// OpenAI's expectations.
    private func encodeMessages(_ messages: [LLMMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(messages)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.badResponse
        }
        return arr
    }

    /// Drains a `streamChat` AsyncThrowingStream into a single String,
    /// honoring task cancellation between deltas.
    func collectStreamedResponse(
        messages: [LLMMessage],
        smart: Bool = false
    ) async throws -> String {
        var full = ""
        for try await delta in streamChat(messages: messages, smart: smart) {
            try Task.checkCancellation()
            full += delta
        }
        return full
    }

    private func readAll(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        data.reserveCapacity(8192)
        for try await byte in bytes.prefix(8192) {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? "<binary>"
    }
}