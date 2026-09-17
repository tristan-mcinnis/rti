import Foundation
import RTICore

/// Shared execution primitive for LLM-powered features.
/// Owns task lifecycle (cancel, start), error normalisation, and the
/// dispatch boundary between network I/O and UI updates.
///
/// Controllers that talk to the LLM (Summary, Title, QA, Chat) compose
/// this instead of duplicating the ~40-line async boilerplate.
final class LLMRequest: @unchecked Sendable {
    /// The tool-aware streaming call, injectable so a test can drive the real
    /// controller and tool loop against a stub instead of a live provider.
    /// The shape is the client's own `streamChatWithTools`.
    typealias ToolStream = @Sendable (
        _ messages: [LLMMessage],
        _ toolsJSON: Data?,
        _ smart: Bool,
        _ route: ChatRouteConfiguration?,
        _ onContent: @Sendable @escaping (String) -> Void,
        _ onReasoning: (@Sendable (String) -> Void)?
    ) async throws -> LLMClient.StreamResult

    private let client: LLMClient
    private let toolStream: ToolStream?
    nonisolated(unsafe) private var currentTask: Task<Void, Never>?

    init(client: LLMClient = .shared, toolStream: ToolStream? = nil) {
        self.client = client
        self.toolStream = toolStream
    }

    var isActive: Bool { currentTask != nil }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Single-flight task primitive

    /// Cancel any in-flight task, then run `work` on the client. Returns nil
    /// on cancellation or if ownership was lost (weak self nil'd). The caller
    /// handles LLMError translation — the primitive only manages task lifecycle.
    private func withSingleFlight<T: Sendable>(
        _ work: @Sendable @escaping (LLMClient) async throws -> T
    ) async -> T? {
        currentTask?.cancel()
        let task = Task { [weak self] () -> T? in
            defer { self?.currentTask = nil }
            guard let client = self?.client else { return nil }
            do {
                let r = try await work(client)
                if Task.isCancelled { return nil }
                return r
            } catch is CancellationError {
                return nil
            } catch is LLMError {
                // Expected provider failure (missing key, HTTP, stream error).
                // Callers (analysis generators) treat nil as "skip this tick".
                return nil
            } catch {
                // Anything else is unexpected — don't let it vanish silently.
                RTILog.log("LLMRequest unexpected error: \(error)", category: .llm)
                return nil
            }
        }
        currentTask = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - Async execution (one-shot collect, tool-aware streaming)

    /// Collect the full streaming response. Returns nil on cancellation, error, or
    /// empty result. Used by title/summary/analysis generators so callers can
    /// await the result before rendering.
    func collectAsync(messages: [LLMMessage], smart: Bool, timeoutOverride: Double? = nil) async -> String? {
        return await withSingleFlight { client in
            try await client.collectStreamedResponse(messages: messages, smart: smart, timeoutOverride: timeoutOverride)
        }
    }

    /// `collectAsync` that keeps the stream's finish reason and reasoning
    /// volume. Use it where an EMPTY answer needs explaining rather than
    /// silently discarding — a reasoning model can burn the whole token
    /// budget on `reasoning_content` and return no text at all. nil still
    /// means cancelled or failed; a non-nil value with empty `text` means the
    /// call succeeded and the model said nothing.
    func collectDetailedAsync(
        messages: [LLMMessage],
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        timeoutOverride: Double? = nil
    ) async -> LLMClient.CollectedResponse? {
        return await withSingleFlight { client in
            try await client.collectDetailedResponse(messages: messages, smart: smart, route: route, timeoutOverride: timeoutOverride)
        }
    }

    /// Tool-aware streaming turn. Yields content/reasoning via callbacks
    /// and returns the assembled tool calls so the caller can execute and
    /// loop. The single in-flight task slot is reused across loop iterations.
    func streamWithTools(
        messages: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMClient.StreamResult {
        currentTask?.cancel()
        let client = self.client
        let toolStream = self.toolStream
        // The task slot holds the ACTUAL streaming task, so `cancel()` cancels
        // the work in flight. The previous shape awaited the stream through a
        // second wrapper task, so cancelling the wrapper left the provider
        // stream running and its deltas still arriving — a cancel that did not
        // cancel. A `ToolStream` override (tests) rides the same path. The
        // result is carried out in a box so the stored task can return Void.
        let box = StreamResultBox()
        let task = Task { [box] in
            do {
                let result: LLMClient.StreamResult
                if let toolStream {
                    result = try await toolStream(messages, toolsJSON, smart, route, onContent, onReasoning)
                } else {
                    result = try await client.streamChatWithTools(
                        messages: messages,
                        toolsJSON: toolsJSON,
                        smart: smart,
                        route: route,
                        onContent: onContent,
                        onReasoning: onReasoning
                    )
                }
                box.store(.success(result))
            } catch {
                box.store(.failure(error))
            }
        }
        currentTask = task
        defer { currentTask = nil }
        await task.value
        guard let stored = box.value else { throw CancellationError() }
        return try stored.get()
    }

    // MARK: - Callback-based streaming

    /// Streaming executor: yields deltas as they arrive. Fire-and-forget —
    /// callbacks deliver results to the caller.
    func stream(
        messages: [LLMMessage],
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        onDelta: @Sendable @escaping (String) -> Void,
        onError: @Sendable @escaping (String, Bool) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            defer {
                self?.currentTask = nil
                onComplete()
            }
            guard let client = self?.client else { return }
            do {
                for try await delta in client.streamChat(messages: messages, smart: smart, route: route, onReasoning: onReasoning) {
                    if Task.isCancelled { return }
                    onDelta(delta)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let llmError = error as? LLMError
                onError(llmError?.userMessage ?? "\(error)", llmError?.isAuth ?? false)
            }
        }
    }
}

/// Carries a stream's outcome out of an unstructured task that returns Void,
/// so the task slot can hold the work itself and cancellation reaches it.
private final class StreamResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<LLMClient.StreamResult, Error>?

    func store(_ result: Result<LLMClient.StreamResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }

    var value: Result<LLMClient.StreamResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
