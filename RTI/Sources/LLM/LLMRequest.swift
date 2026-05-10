import Foundation

/// Shared execution primitive for LLM-powered features.
/// Owns task lifecycle (cancel, start), error normalisation, and the
/// dispatch boundary between network I/O and UI updates.
///
/// Controllers that talk to the LLM (Summary, Title, QA, Chat) compose
/// this instead of duplicating the ~40-line async boilerplate.
final class LLMRequest {
    private let client: LLMClient
    private var currentTask: Task<Void, Never>?

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
        onResult: @escaping (String) -> Void,
        onError: @escaping (String, Bool) -> Void
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
        var result: String?
        let task = Task { [weak self] in
            defer { self?.currentTask = nil }
            guard let client = self?.client else { return }
            do {
                result = try await client.collectStreamedResponse(messages: messages, smart: smart)
                if Task.isCancelled { result = nil }
            } catch is CancellationError {
                result = nil
            } catch {
                if Task.isCancelled { result = nil }
            }
        }
        currentTask = task
        await task.value
        return result
    }

    /// Streaming executor: yields deltas as they arrive. Used by
    /// LLMController and SessionQAController.
    func stream(
        messages: [LLMMessage],
        smart: Bool,
        onDelta: @escaping (String) -> Void,
        onError: @escaping (String, Bool) -> Void,
        onComplete: @escaping () -> Void,
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
