import Foundation

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
        let model = provider.model
        let temperature: Double? = smart ? nil : 0.6
        let thinking: LLMWireRequest.Thinking? = provider.supportsThinking
            ? LLMWireRequest.Thinking(type: smart ? "enabled" : "disabled")
            : nil
        let streamTimeoutSeconds: Double = smart ? 120 : 60

        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LLMError.missingAPIKey)
            }
        }

        let providerName = provider.displayName
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = LLMWireRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        temperature: temperature,
                        max_tokens: 1024,
                        thinking: thinking
                    )
                    var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)

                    RTILog.log("POST provider=\(providerName) model=\(model) messages=\(messages.count) smart=\(smart)", category: "llm")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.badResponse
                    }
                    RTILog.log("HTTP \(http.statusCode) provider=\(providerName)", category: "llm")
                    guard (200..<300).contains(http.statusCode) else {
                        let errText = try await readAll(bytes)
                        if http.statusCode == 401 {
                            throw LLMError.unauthorized
                        }
                        throw LLMError.httpError(http.statusCode, errText)
                    }

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(streamTimeoutSeconds * 1_000_000_000))
                            throw LLMError.streamError("Stream timed out after \(Int(streamTimeoutSeconds))s")
                        }
                        group.addTask { [weak self] in
                            guard let self else { return }
                            _ = try await self.processStreamBytes(bytes, onContent: { delta in
                                continuation.yield(delta)
                            }, onReasoning: onReasoning)
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
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
        let model = provider.model
        let temperature: Double? = smart ? nil : 0.6
        let streamTimeoutSeconds: Double = smart ? 120 : 60
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        let providerName = provider.displayName

        var bodyDict: [String: Any] = [
            "model": model,
            "messages": try encodeMessages(messages),
            "stream": true,
            "max_tokens": 1024
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

        var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

        let toolCountForLog = (bodyDict["tools"] as? [Any])?.count ?? 0
        RTILog.log("POST provider=\(providerName) tools=\(toolCountForLog) messages=\(messages.count) smart=\(smart)", category: "llm")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let errText = try await readAll(bytes)
            if http.statusCode == 401 { throw LLMError.unauthorized }
            throw LLMError.httpError(http.statusCode, errText)
        }

        return try await withThrowingTaskGroup(of: StreamResult.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(streamTimeoutSeconds * 1_000_000_000))
                throw LLMError.streamError("Stream timed out after \(Int(streamTimeoutSeconds))s")
            }
            group.addTask { [weak self] in
                guard let self else { return StreamResult(toolCalls: [], finishReason: nil) }
                return try await self.processStreamBytes(
                    bytes,
                    onContent: { delta in
                        DispatchQueue.main.async { onContent(delta) }
                    },
                    onReasoning: onReasoning
                )
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
        let decoder = JSONDecoder()
        // Keyed by stream-chunk `index`. Tool-call fragments arrive in
        // sequence: id+name in the first chunk for an index, then
        // `arguments` deltas concatenated until finish_reason fires.
        var toolBuffer: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Comments per SSE spec start with a colon.
            if line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

            // Some servers send {"error": {...}} mid-stream instead of
            // [DONE]. Surface that to the caller.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] {
                let detail: String = {
                    if let msg = err as? [String: Any], let text = msg["message"] as? String { return text }
                    return "\(err)"
                }()
                throw LLMError.streamError(detail)
            }

            do {
                let chunk = try decoder.decode(LLMStreamChunk.self, from: data)
                guard let choice = chunk.choices.first else { continue }
                if let reason = choice.finish_reason { finishReason = reason }
                if let reasoning = choice.delta?.reasoning_content, !reasoning.isEmpty,
                   let onReasoning {
                    DispatchQueue.main.async { onReasoning(reasoning) }
                }
                if let content = choice.delta?.content, !content.isEmpty {
                    onContent(content)
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
            } catch {
                RTILog.log("SSE chunk decode failed: \(error)", category: "llm")
            }
        }

        let toolCalls = toolBuffer
            .sorted { $0.key < $1.key }
            .compactMap { (_, v) -> LLMToolCall? in
                guard !v.id.isEmpty, !v.name.isEmpty else { return nil }
                return LLMToolCall(id: v.id, type: "function",
                                   function: .init(name: v.name, arguments: v.args))
            }
        return StreamResult(toolCalls: toolCalls, finishReason: finishReason)
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