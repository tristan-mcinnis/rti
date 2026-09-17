import Foundation
import RTICore

/// Streaming chat client for any OpenAI-compatible provider.
/// Provider behavior (URL, model, API key, optional `thinking` extension)
/// is supplied via `LLMProviderConfig`; routing to a different LLM is a
/// one-line change in `LLMProviders` rather than edits here.
final class LLMClient: @unchecked Sendable {
    /// Shared instance bound to the active provider. Every LLM-using
    /// controller routes through this. Provider resolution happens at call
    /// time, so switching providers or keys in Settings takes effect on the
    /// next request without rebuilding the singleton.
    static let shared = LLMClient()

    private let providerResolver: @Sendable () -> LLMProviderConfig
    private let session: URLSession

    /// Hard ceiling on output tokens per completion. Set to DeepSeek's maximum
    /// (8192) rather than the old 4096: a full-meeting Granola summary of a 2h+
    /// session — especially bilingual, where CJK + pinyin burn tokens fast —
    /// blew past 4096 and got cut off mid-sentence. This is a CEILING, not a
    /// target: the short quick actions self-limit via their prompts and stop
    /// well before it, so raising it costs them nothing.
    private static let maxOutputTokens = 8192

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    init(providerResolver: @escaping @Sendable () -> LLMProviderConfig = { LLMProviders.active }) {
        self.providerResolver = providerResolver
        self.session = Self.sharedSession
    }

    convenience init(provider: LLMProviderConfig) {
        self.init(providerResolver: { provider })
    }

    private var provider: LLMProviderConfig { providerResolver() }

    // MARK: - Stream result

    /// Output from a single chat-completion stream.
    struct StreamResult: Sendable {
        let toolCalls: [LLMToolCall]
        let finishReason: String?
        /// How many characters of `reasoning_content` arrived. Counted even
        /// when no `onReasoning` listener is attached: when a reasoning model
        /// returns no content at all, the reasoning volume plus
        /// `finishReason` is the only evidence of why.
        let reasoningCharacters: Int
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
        route: ChatRouteConfiguration? = nil,
        timeoutOverride: Double? = nil,
        onReasoning: (@Sendable (String) -> Void)? = nil,
        onFinish: (@Sendable (StreamResult) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        // A frozen route wins over the live registry and over `smart`: the
        // turn runs on the provider, model, and key it started with.
        let frozen = route ?? self.route(smart: smart)
        let provider = frozen.provider
        let apiKey = provider.apiKey()
        let isSmart = frozen.smart
        let temperature: Double? = isSmart ? nil : 0.6
        let thinking: LLMWireRequest.Thinking? = provider.supportsThinking
            ? LLMWireRequest.Thinking(type: isSmart ? "enabled" : "disabled")
            : nil
        let timeoutSeconds: Double = timeoutOverride ?? (isSmart ? 120 : 60)

        guard !apiKey.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.missingAPIKey) }
        }

        let logDetail = "model=\(provider.model) messages=\(messages.count) smart=\(isSmart)"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(LLMWireRequest(
                        model: provider.model,
                        messages: messages,
                        stream: true,
                        temperature: temperature,
                        max_tokens: Self.maxOutputTokens,
                        thinking: thinking
                    ))
                    // Plain path yields each delta straight to the stream's
                    // consumer — no main-thread hop (the caller decides).
                    let result = try await performChatStream(
                        httpBody: body,
                        provider: provider,
                        apiKey: apiKey,
                        logDetail: logDetail,
                        timeoutSeconds: timeoutSeconds,
                        onContent: { continuation.yield($0) },
                        onReasoning: onReasoning
                    )
                    onFinish?(result)
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
        route: ChatRouteConfiguration? = nil,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> StreamResult {
        let frozen = route ?? self.route(smart: smart)
        let provider = frozen.provider
        let apiKey = provider.apiKey()
        let isSmart = frozen.smart
        let temperature: Double? = isSmart ? nil : 0.6
        let timeoutSeconds: Double = isSmart ? 120 : 60

        var bodyDict: [String: Any] = [
            "model": provider.model,
            "messages": try encodeMessages(messages),
            "stream": true,
            "max_tokens": Self.maxOutputTokens
        ]
        if let temperature { bodyDict["temperature"] = temperature }
        if provider.supportsThinking {
            bodyDict["thinking"] = ["type": isSmart ? "enabled" : "disabled"]
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
            provider: provider,
            apiKey: apiKey,
            logDetail: "tools=\(toolCount) messages=\(messages.count) smart=\(isSmart)",
            timeoutSeconds: timeoutSeconds,
            onContent: { delta in DispatchQueue.main.async { onContent(delta) } },
            onReasoning: onReasoning
        )
    }

    /// A route for a caller that has none: today's live registry entry, with
    /// `smart` carried as an explicit reasoning choice. Keeps the analysis and
    /// title generators on one code path without making them resolve a
    /// per-chat selection they do not have.
    private func route(smart: Bool) -> ChatRouteConfiguration {
        let provider = self.provider
        let reasoning: ChatReasoningMode = smart ? .thinking : .fast
        return ChatRouteConfiguration(
            provider: provider,
            reasoning: reasoning,
            imageRoute: .none,
            imageCount: 0,
            selection: ChatModelSelection(
                providerId: provider.id,
                model: nil,
                reasoning: reasoning
            )
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
        provider: LLMProviderConfig,
        apiKey: String,
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

        RTILog.log("POST provider=\(providerName) \(logDetail)", category: .llm)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        RTILog.log("HTTP \(http.statusCode) provider=\(providerName)", category: .llm)
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
                guard let self else { return StreamResult(toolCalls: [], finishReason: nil, reasoningCharacters: 0) }
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
        var reasoningCharacters = 0
        lines: for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            for event in parser.consume(line: rawLine) {
                switch event {
                case .content(let content):
                    onContent(content)
                case .reasoning(let reasoning):
                    reasoningCharacters += reasoning.count
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
        return StreamResult(
            toolCalls: parser.assembledToolCalls(),
            finishReason: parser.finishReason,
            reasoningCharacters: reasoningCharacters
        )
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

    /// A collected completion: the text, why the stream ended, and how much
    /// hidden reasoning arrived on the way.
    ///
    /// `text` can be empty while nothing threw. A reasoning model spends its
    /// `max_tokens` budget on `reasoning_content` BEFORE it writes a word, so
    /// a long deliberation can end the stream (`finishReason == "length"`)
    /// having emitted no content at all. Callers must treat empty text as a
    /// failure; these fields let them log WHY instead of guessing.
    struct CollectedResponse: Sendable {
        let text: String
        let finishReason: String?
        let reasoningCharacters: Int

        /// The reason, in words, for a log line.
        var emptyReasonDescription: String {
            "finish_reason=\(finishReason ?? "none"), \(reasoningCharacters) reasoning chars, 0 content chars"
        }
    }

    /// Drains a `streamChat` AsyncThrowingStream into a single String,
    /// honoring task cancellation between deltas.
    func collectStreamedResponse(
        messages: [LLMMessage],
        smart: Bool = false,
        route: ChatRouteConfiguration? = nil,
        timeoutOverride: Double? = nil
    ) async throws -> String {
        try await collectDetailedResponse(
            messages: messages,
            smart: smart,
            route: route,
            timeoutOverride: timeoutOverride
        ).text
    }

    /// `collectStreamedResponse` plus the stream's finish reason and reasoning
    /// volume, so a caller that gets no text can say why.
    func collectDetailedResponse(
        messages: [LLMMessage],
        smart: Bool = false,
        route: ChatRouteConfiguration? = nil,
        timeoutOverride: Double? = nil
    ) async throws -> CollectedResponse {
        let box = FinishBox()
        var full = ""
        for try await delta in streamChat(
            messages: messages,
            smart: smart,
            route: route,
            timeoutOverride: timeoutOverride,
            onFinish: { box.store($0) }
        ) {
            try Task.checkCancellation()
            full += delta
        }
        let result = box.value
        return CollectedResponse(
            text: full,
            finishReason: result?.finishReason,
            reasoningCharacters: result?.reasoningCharacters ?? 0
        )
    }

    /// Carries the stream's `StreamResult` out of the `onFinish` callback,
    /// which fires on the streaming task rather than the awaiting one.
    private final class FinishBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StreamResult?

        func store(_ result: StreamResult) {
            lock.lock()
            defer { lock.unlock() }
            stored = result
        }

        var value: StreamResult? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
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
