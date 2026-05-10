import Foundation

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

    /// One-shot collector: waits for the full response then fires the
    /// callback. Used by SummaryController and SessionTitleController.
    func collect(
        messages: [LLMMessage],
        smart: Bool,
        onResult: @Sendable @escaping (String) -> Void,
        onError: @Sendable @escaping (String, Bool) -> Void
    ) {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            defer { self?.currentTask = nil }
            guard let client = self?.client else { return }
            do {
                let result = try await client.collectStreamedResponse(messages: messages, smart: smart)
                if Task.isCancelled { return }
                onResult(result)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let llmError = error as? LLMError
                onError(llmError?.userMessage ?? "\(error)", llmError?.isAuth ?? false)
            }
        }
    }

    /// Async variant of collect: returns the full response on success,
    /// nil on error or cancellation. Used by the async title/summary
    /// generators so callers can await the result before rendering.
    func collectAsync(messages: [LLMMessage], smart: Bool) async -> String? {
        currentTask?.cancel()
        let task = Task { [weak self] () -> String? in
            defer { self?.currentTask = nil }
            guard let client = self?.client else { return nil }
            do {
                let r = try await client.collectStreamedResponse(messages: messages, smart: smart)
                if Task.isCancelled { return nil }
                return r
            } catch is CancellationError {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                return nil
            }
        }
        currentTask = Task { _ = await task.value }
        return await task.value
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
    ) async throws -> LLMClient.ToolAwareStreamResult {
        currentTask?.cancel()
        let task = Task { [client] () throws -> LLMClient.ToolAwareStreamResult in
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

    /// Streaming executor: yields deltas as they arrive. Used by
    /// LLMController and SessionQAController.
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
