import Foundation
import RTICore

/// Shared execution primitive for LLM-powered features.
/// Owns task lifecycle (cancel, start), error normalisation, and the
/// dispatch boundary between network I/O and UI updates.
///
/// Controllers that talk to the LLM (Summary, Title, QA, Chat) compose
/// this instead of duplicating the ~40-line async boilerplate.
final class LLMRequest: @unchecked Sendable {
    private let client: LLMClient
    nonisolated(unsafe) private var currentTask: Task<Void, Never>?

    init(client: LLMClient = .shared) {
        self.client = client
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
        timeoutOverride: Double? = nil
    ) async -> LLMClient.CollectedResponse? {
        return await withSingleFlight { client in
            try await client.collectDetailedResponse(messages: messages, smart: smart, timeoutOverride: timeoutOverride)
        }
    }

    /// Tool-aware streaming turn. Yields content/reasoning via callbacks
    /// and returns the assembled tool calls so the caller can execute and
    /// loop. The single in-flight task slot is reused across loop iterations.
    func streamWithTools(
        messages: [LLMMessage],
        toolsJSON: Data?,
        smart: Bool,
        onContent: @Sendable @escaping (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMClient.StreamResult {
        currentTask?.cancel()
        // streamWithTools must not use withSingleFlight for the inner task —
        // the caller (ToolLoop) manages the outer task slot. We only gate
        // and capture the client here.
        let task = Task { [client] () throws -> LLMClient.StreamResult in
            try await client.streamChatWithTools(
                messages: messages,
                toolsJSON: toolsJSON,
                smart: smart,
                onContent: onContent,
                onReasoning: onReasoning
            )
        }
        currentTask = Task { _ = try? await task.value }
        defer { currentTask = nil }
        return try await task.value
    }

    // MARK: - Callback-based streaming

    /// Streaming executor: yields deltas as they arrive. Fire-and-forget —
    /// callbacks deliver results to the caller.
    func stream(
        messages: [LLMMessage],
        smart: Bool,
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
                for try await delta in client.streamChat(messages: messages, smart: smart, onReasoning: onReasoning) {
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
