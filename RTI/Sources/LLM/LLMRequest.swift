import Foundation
import RTICore

/// Shared execution primitive for LLM-powered features.
/// Owns task lifecycle (cancel, start), error normalisation, and the
/// dispatch boundary between network I/O and UI updates.
///
/// Controllers that talk to the LLM (Summary, Title, QA, Chat) compose
/// this instead of duplicating the ~40-line async boilerplate.
///
/// `priority` decides how the request is admitted against the shared
/// `LLMAdmissionController`:
/// * `.foreground` (the default) is admitted immediately and holds a slot
///   while it runs, so queued background work waits.
/// * `.background` waits for foreground to settle, yields if foreground
///   arrives mid-flight, and retries the yield a bounded number of times.
///
/// `streamWithTools` — the interactive tool-aware turn — is foreground by
/// construction; the tool loop holds one foreground permit for the whole
/// multi-round turn (see `ToolLoop.run`).
// Immutable dependencies are Sendable; mutable task ownership is guarded by
// RequestFlight's lock. No request lifecycle state is accessed without it.
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

    /// The collected-response call behind `collectAsync`/`collectDetailedAsync`,
    /// injectable so a scheduling test can drive the admission gate without a
    /// live provider. Nil uses the client's own collected call.
    typealias CollectStream = @Sendable (
        _ messages: [LLMMessage],
        _ smart: Bool,
        _ route: ChatRouteConfiguration?,
        _ timeoutOverride: Double?
    ) async throws -> LLMClient.CollectedResponse

    /// How many times a background request yields to foreground before it
    /// gives up and reports a failure. Bounded so a continuously busy live
    /// surface can never pin a background request in an infinite requeue.
    static let backgroundPreemptionAttempts = 6

    private let client: LLMClient
    private let toolStream: ToolStream?
    private let collectStream: CollectStream?
    private let priority: LLMPriority
    private let admission: LLMAdmissionController
    private let flight = RequestFlight()

    init(
        client: LLMClient = .shared,
        toolStream: ToolStream? = nil,
        collectStream: CollectStream? = nil,
        priority: LLMPriority = .foreground,
        admission: LLMAdmissionController = .shared
    ) {
        self.client = client
        self.toolStream = toolStream
        self.collectStream = collectStream
        self.priority = priority
        self.admission = admission
    }

    var isActive: Bool { flight.isActive }

    func cancel() {
        flight.cancel()
    }

    // MARK: - Foreground turn permit

    /// Hold foreground priority for a whole multi-round tool turn, so a
    /// background request cannot slip between rounds. Release with
    /// `endForegroundTurn`.
    func beginForegroundTurn() async -> LLMLease {
        await admission.acquireForeground()
    }

    func endForegroundTurn(_ lease: LLMLease) async {
        await admission.releaseForeground(lease)
    }

    // MARK: - Async execution (one-shot collect, tool-aware streaming)

    /// Collect the full streaming response. Returns nil on cancellation, error, or
    /// empty result. Used by title/summary/analysis generators so callers can
    /// await the result before rendering.
    func collectAsync(messages: [LLMMessage], smart: Bool, timeoutOverride: Double? = nil) async -> String? {
        let collected = await collectedResponse(messages: messages, smart: smart, route: nil, timeoutOverride: timeoutOverride)
        return collected?.text
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
        await collectedResponse(messages: messages, smart: smart, route: route, timeoutOverride: timeoutOverride)
    }

    /// Existing analysis callers intentionally treat any failure as nil.
    private func collectedResponse(
        messages: [LLMMessage],
        smart: Bool,
        route: ChatRouteConfiguration?,
        timeoutOverride: Double?
    ) async -> LLMClient.CollectedResponse? {
        try? await collectDetailedThrowingAsync(
            messages: messages, smart: smart, route: route, timeoutOverride: timeoutOverride
        )
    }

    /// User-triggered generators need the actual provider/scheduling error,
    /// not the optional compatibility result used by periodic analysis ticks.
    func collectDetailedThrowingAsync(
        messages: [LLMMessage],
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        timeoutOverride: Double? = nil
    ) async throws -> LLMClient.CollectedResponse {
        let collectStream = self.collectStream
        let frozenRoute = route ?? client.snapshotRoute(smart: smart)
        return try await gatedCollect { client in
            if let collectStream {
                return try await collectStream(messages, smart, frozenRoute, timeoutOverride)
            }
            return try await client.collectDetailedResponse(
                messages: messages,
                smart: smart,
                route: frozenRoute,
                timeoutOverride: timeoutOverride
            )
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
        let generation = flight.begin(replacing: true)!
        let client = self.client
        let toolStream = self.toolStream
        let admission = self.admission
        let flight = self.flight
        let box = RequestResultBox<LLMClient.StreamResult>()
        // Owned by the existing synchronous cancel() API; parent cancellation
        // is explicitly forwarded. The tool loop also holds a turn-wide lease.
        let task = Task { [box] in
            defer { flight.finish(generation) }
            let lease = await admission.acquireForeground()
            do {
                try Task.checkCancellation()
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
            await admission.releaseForeground(lease)
        }
        flight.install(task, for: generation)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard let stored = box.value else { throw CancellationError() }
        return try stored.get()
    }

    // MARK: - Callback-based streaming

    /// Streaming executor: yields deltas as they arrive. Fire-and-forget —
    /// callbacks deliver results to the caller. Always holds foreground admission
    /// for the life of the stream, and releases it on every
    /// exit path including cancellation.
    func stream(
        messages: [LLMMessage],
        smart: Bool,
        route: ChatRouteConfiguration? = nil,
        onDelta: @Sendable @escaping (String) -> Void,
        onError: @Sendable @escaping (String, Bool) -> Void,
        onComplete: @Sendable @escaping () -> Void,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) {
        guard let generation = flight.begin(replacing: false) else { return }
        let client = self.client
        let admission = self.admission
        let flight = self.flight
        // Callback streaming is interactive: emitted deltas cannot be safely
        // replayed. Deferred callers use the cancellable/requeued collect path.
        let task = Task {
            defer {
                flight.finish(generation)
                onComplete()
            }
            let lease = await admission.acquireForeground()
            do {
                try Task.checkCancellation()
                for try await delta in client.streamChat(
                    messages: messages,
                    smart: smart,
                    route: route,
                    onReasoning: onReasoning
                ) {
                    if Task.isCancelled { break }
                    onDelta(delta)
                }
            } catch is CancellationError {
                // Normal lifecycle event, not a provider error.
            } catch {
                if !Task.isCancelled {
                    let llmError = error as? LLMError
                    onError(llmError?.userMessage ?? "\(error)", llmError?.isAuth ?? false)
                }
            }
            await admission.releaseForeground(lease)
        }
        flight.install(task, for: generation)
    }

    // MARK: - Admission gate

    private enum GateOutcome<T: Sendable>: Sendable {
        case value(T)
        case failed(any Error)
        case preempted
    }

    private func gatedCollect<T: Sendable>(
        _ work: @Sendable @escaping (LLMClient) async throws -> T
    ) async throws -> T {
        let generation = flight.begin(replacing: true)!
        let flight = self.flight
        let box = RequestResultBox<T>()
        // One owned task bridges sync cancel(); preemption children are structured.
        let task = Task { [self] in
            defer { flight.finish(generation) }
            do {
                let value = try await runGate(work)
                try Task.checkCancellation()
                box.store(.success(value))
            } catch {
                box.store(.failure(error))
            }
        }
        flight.install(task, for: generation)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard let result = box.value else { throw CancellationError() }
        return try result.get()
    }

    private func runGate<T: Sendable>(
        _ work: @Sendable @escaping (LLMClient) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        switch priority {
        case .foreground:
            let lease = await admission.acquireForeground()
            do {
                try Task.checkCancellation()
                let result = try await work(client)
                try Task.checkCancellation()
                await admission.releaseForeground(lease)
                return result
            } catch {
                await admission.releaseForeground(lease)
                throw error
            }
        case .background:
            var attempt = 0
            while true {
                try Task.checkCancellation()
                guard let slot = await admission.acquireBackground() else { throw CancellationError() }
                let outcome = await raceAgainstForeground(epoch: slot.epoch, work: work)
                await admission.releaseBackground(slot.lease)
                try Task.checkCancellation()
                switch outcome {
                case let .value(value): return value
                case let .failed(error): throw error
                case .preempted:
                    attempt += 1
                    if attempt >= Self.backgroundPreemptionAttempts {
                        throw LLMRequestSchedulingError.foregroundBusy
                    }
                }
            }
        }
    }

    /// Run a background request racing the foreground-arrival signal. Whichever
    /// finishes first wins; the loser is cancelled (a yield, not a failure).
    private func raceAgainstForeground<T: Sendable>(
        epoch: UInt64,
        work: @Sendable @escaping (LLMClient) async throws -> T
    ) async -> GateOutcome<T> {
        let client = self.client
        let admission = self.admission
        return await withTaskGroup(of: GateOutcome<T>.self) { group in
            group.addTask {
                do {
                    let value = try await work(client)
                    return .value(value)
                } catch is CancellationError {
                    return .preempted
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                await admission.waitForForegroundChange(after: epoch)
                return .preempted
            }
            guard let first = await group.next() else { return .preempted }
            group.cancelAll()
            return first
        }
    }
}

enum LLMRequestSchedulingError: LocalizedError {
    case foregroundBusy

    var errorDescription: String? {
        "Background work yielded to live requests repeatedly. Try again after the live request finishes."
    }
}

/// The lock guards the result carried out of the owned Void task.
private final class RequestResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Lock-guarded single-flight ownership bridges sync cancel() and async work.
/// Generation checks prevent an older completion from clearing a newer task.
private final class RequestFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    private var task: Task<Void, Never>?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation != nil
    }

    func begin(replacing: Bool) -> UUID? {
        lock.lock()
        guard replacing || generation == nil else {
            lock.unlock()
            return nil
        }
        let previous = task
        let next = UUID()
        generation = next
        task = nil
        lock.unlock()
        previous?.cancel()
        return next
    }

    func install(_ task: Task<Void, Never>, for generation: UUID) {
        lock.lock()
        let ownsFlight = self.generation == generation
        if ownsFlight { self.task = task }
        lock.unlock()
        if !ownsFlight { task.cancel() }
    }

    func finish(_ generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return }
        self.generation = nil
        task = nil
    }

    func cancel() {
        lock.lock()
        let previous = task
        generation = nil
        task = nil
        lock.unlock()
        previous?.cancel()
    }
}
