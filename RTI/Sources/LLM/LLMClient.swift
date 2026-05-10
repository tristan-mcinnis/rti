import Foundation

/// Streaming chat client for any OpenAI-compatible provider.
/// Provider behavior (URL, model, API key, optional `thinking` extension)
/// is supplied via `LLMProviderConfig`; routing to a different LLM is a
/// one-line change in `LLMProviders` rather than edits here.
final class LLMClient: @unchecked Sendable {
    /// Shared instance bound to the active provider. All four LLM-using
    /// controllers (LLMController, SummaryController, SessionTitleController,
    /// SessionQAController) route through this. `apiKey` is resolved at
    /// call time, so key edits in Settings take effect on the next request
    /// without rebinding the singleton.
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

    /// Streams `delta.content` strings from a chat completion as they
    /// arrive. The stream terminates on `data: [DONE]` sentinel or on
    /// error.
    ///
    /// `smart=true` enables provider-side reasoning when the config
    /// reports `supportsThinking=true`; otherwise it degrades to a normal
    /// completion. `onReasoning`, when supplied, fires on the main thread
    /// for every reasoning_content chunk in smart mode. LLMController
    /// uses it to drive the "reasoning…" indicator; other callers leave
    /// it nil.
    func streamChat(
        messages: [LLMMessage],
        smart: Bool = false,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let model = provider.model
        // Thinking mode ignores sampling params; only send temperature
        // when thinking is disabled.
        let temperature: Double? = smart ? nil : 0.6
        let thinking: LLMWireRequest.Thinking? = provider.supportsThinking
            ? LLMWireRequest.Thinking(type: smart ? "enabled" : "disabled")
            : nil
        // Smart mode runs reasoning before any content, so the first byte
        // can take much longer to arrive than chat. URLRequest.timeout-
        // Interval is ignored by the async URLSession API — we use the
        // group below instead.
        let streamTimeoutSeconds: Double = smart ? 120 : 60
        // Fast-fail on missing API key before encoding the request body.
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
                        // Cost guardrail. Without this, a long meeting
                        // transcript fed every turn could rack up bills
                        // unbounded. 1024 fits all four prompt shapes
                        // (Assist/Say/Followups/Recap) plus typical chat.
                        max_tokens: 1024,
                        thinking: thinking
                    )
                    var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(body)

                    NSLog("[RTI] LLMClient[\(providerName)]: POST \(request.url?.absoluteString ?? "?") model=\(model) messages=\(messages.count)")
                    RTILog.log("POST provider=\(providerName) model=\(model) messages=\(messages.count) smart=\(smart)", category: "llm")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.badResponse
                    }
                    NSLog("[RTI] LLMClient[\(providerName)]: HTTP \(http.statusCode)")
                    RTILog.log("HTTP \(http.statusCode)", category: "llm")
                    guard (200..<300).contains(http.statusCode) else {
                        let errText = try await readAll(bytes)
                        if http.statusCode == 401 {
                            throw LLMError.unauthorized
                        }
                        throw LLMError.httpError(http.statusCode, errText)
                    }

                    // Race the SSE stream against a timeout. URLRequest.timeoutInterval
                    // is only advisory for the async bytes API, so we enforce the window
                    // ourselves. This way a hung stream fails fast at 60s (120s in smart
                    // mode) instead of waiting for URLSession's resource timeout (300s).
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(streamTimeoutSeconds * 1_000_000_000))
                            throw LLMError.streamError("Stream timed out after \(Int(streamTimeoutSeconds))s")
                        }
                        group.addTask { [weak self] in
                            guard let self else { return }
                            try await processStream(bytes, continuation: continuation, onReasoning: onReasoning)
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Result of a single tool-aware streaming turn.
    /// - `toolCalls` is non-empty when the model wants the host to run
    ///   functions (finish_reason = tool_calls). The caller executes them
    ///   and re-streams with the results appended as `tool` messages.
    /// - `finishReason` is the raw provider reason (e.g. "stop", "tool_calls",
    ///   "length"). Surfaced for diagnostics.
    struct ToolAwareStreamResult {
        let toolCalls: [LLMToolCall]
        let finishReason: String?
    }

    /// Streaming chat with OpenAI-style tool support. Yields content deltas
    /// + reasoning via callbacks (so the UI can paint as tokens arrive),
    /// accumulates any tool_calls fragments, and returns the assembled
    /// tool-call list when the stream finishes. The caller drives the
    /// tool-call loop (execute → append tool messages → re-call).
    ///
    /// `tools` is a pre-built JSON array (see `LLMToolRegistry.wireFormat()`).
    /// Pass an empty array to disable tools for this turn.
    func streamChatWithTools(
        messages: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> ToolAwareStreamResult {
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
        NSLog("[RTI] LLMClient[\(providerName)]: POST tools=\(toolCountForLog) messages=\(messages.count)")
        RTILog.log("POST tools=\(toolCountForLog) messages=\(messages.count) smart=\(smart)", category: "llm")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let errText = try await readAll(bytes)
            if http.statusCode == 401 { throw LLMError.unauthorized }
            throw LLMError.httpError(http.statusCode, errText)
        }

        return try await withThrowingTaskGroup(of: ToolAwareStreamResult.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(streamTimeoutSeconds * 1_000_000_000))
                throw LLMError.streamError("Stream timed out after \(Int(streamTimeoutSeconds))s")
            }
            group.addTask { [weak self] in
                guard let self else { return ToolAwareStreamResult(toolCalls: [], finishReason: nil) }
                return try await self.processToolStream(bytes, onContent: onContent, onReasoning: onReasoning)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Encodes `[LLMMessage]` into the JSON-friendly form used by
    /// `JSONSerialization`. Drops nil fields so the wire body matches
    /// OpenAI's expectations (e.g. tool messages omit `tool_calls`).
    private func encodeMessages(_ messages: [LLMMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(messages)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.badResponse
        }
        return arr
    }

    private func processToolStream(
        _ bytes: URLSession.AsyncBytes,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)?
    ) async throws -> ToolAwareStreamResult {
        let decoder = JSONDecoder()
        // Keyed by stream-chunk `index`. Tool-call fragments arrive in
        // sequence: id+name in the first chunk for an index, then
        // `arguments` deltas concatenated until finish_reason fires.
        var toolBuffer: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason: String?

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }

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
                    DispatchQueue.main.async { onContent(content) }
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
                NSLog("[RTI] LLMClient tool-stream chunk decode failed: \(error)")
            }
        }

        let toolCalls = toolBuffer
            .sorted { $0.key < $1.key }
            .compactMap { (_, v) -> LLMToolCall? in
                guard !v.id.isEmpty, !v.name.isEmpty else { return nil }
                return LLMToolCall(id: v.id, type: "function",
                                   function: .init(name: v.name, arguments: v.args))
            }
        return ToolAwareStreamResult(toolCalls: toolCalls, finishReason: finishReason)
    }

    /// Drains a `streamChat` AsyncThrowingStream into a single String,
    /// honoring task cancellation between deltas. Used by the one-shot
    /// generators (Summary, Title) that need the full response before
    /// parsing, rather than per-delta UI updates.
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

    private func processStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        onReasoning: (@Sendable (String) -> Void)?
    ) async throws {
        let decoder = JSONDecoder()
        let providerName = provider.displayName
        var lineCount = 0
        var deltaCount = 0
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1
            // Strip CRLF and surrounding whitespace per the SSE spec; some
            // proxies emit `\r\n` and providers vary on the space after
            // `data:`. The first 200 chars are still logged but redacted
            // (no raw response bodies — they can leak auth headers or
            // upstream errors that include keys).
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if lineCount <= 3 {
                let preview = line.hasPrefix("data:") ? "data: …" : line.prefix(60)
                NSLog("[RTI] LLMClient[\(providerName)] line[\(lineCount)]: %@", String(preview) as NSString)
            }
            // Comments per SSE spec start with a colon.
            if line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                NSLog("[RTI] LLMClient[\(providerName)]: [DONE] lines=\(lineCount) deltas=\(deltaCount)")
                RTILog.log("done — lines=\(lineCount) deltas=\(deltaCount)", category: "llm")
                continuation.finish()
                return
            }
            guard let data = payload.data(using: .utf8) else { continue }
            // After trimming, the local `payload` is a `Substring`; downstream
            // JSON paths still work on `data`.
            let payloadString = String(payload)
            // Some servers send {"error": {...}} mid-stream instead of
            // [DONE]. Surface that to the caller instead of silently
            // swallowing it.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] {
                let detail: String = {
                    if let msg = err as? [String: Any], let text = msg["message"] as? String {
                        return text
                    }
                    return "\(err)"
                }()
                throw LLMError.streamError(detail)
            }
            do {
                let chunk = try decoder.decode(LLMStreamChunk.self, from: data)
                if let reasoning = chunk.choices.first?.delta?.reasoning_content, !reasoning.isEmpty,
                   let onReasoning {
                    DispatchQueue.main.async { onReasoning(reasoning) }
                }
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    deltaCount += 1
                    continuation.yield(delta)
                }
            } catch {
                NSLog("[RTI] LLMClient[\(providerName)] chunk decode failed: \(error) payload=\(payloadString.prefix(200))")
            }
        }
        continuation.finish()
    }
}
