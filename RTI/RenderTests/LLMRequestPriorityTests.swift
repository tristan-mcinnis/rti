import RTICore
import XCTest

/// Deterministic tests for `LLMRequest`'s admission gate: a background collect
/// waits for foreground, yields when foreground arrives mid-flight and resumes,
/// a cancelled collect stops promptly and leaves the scheduler healthy, and
/// `stream()` participates in admission too.
///
/// Everything runs against an injected `LLMAdmissionController` and a stub
/// collect closure; no provider call, no network, no real vault.
final class LLMRequestPriorityTests: XCTestCase {

    // MARK: - Helpers

    /// Lock-guarded counter.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    /// A stub collect call that blocks its first invocation until the task is
    /// cancelled, signalling when it has started.
    private final class BlockingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isStarted = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var callContinuation: CheckedContinuation<Void, Error>?
        private var cancelledEarly = false

        /// Block until the caller is cancelled, then throw `CancellationError`.
        func blockUntilCancelled() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if cancelledEarly {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    callContinuation = continuation
                    isStarted = true
                    let waiters = startedWaiters
                    startedWaiters.removeAll()
                    lock.unlock()
                    for waiter in waiters { waiter.resume() }
                }
            } onCancel: {
                lock.lock()
                if let continuation = callContinuation {
                    callContinuation = nil
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    cancelledEarly = true
                    lock.unlock()
                }
            }
        }

        /// Wait until the first `blockUntilCancelled()` call has installed its
        /// continuation.
        func waitUntilStarted() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isStarted {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                startedWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    @discardableResult
    private func yieldUntil(_ predicate: () -> Bool, attempts: Int = 200) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    // MARK: - Waiting

    func testBackgroundCollectWaitsForHeldForeground() async {
        let controller = LLMAdmissionController()
        let calls = Counter()
        let collect: LLMRequest.CollectStream = { _, _, _, _ in
            calls.increment()
            return collectedResponse("done")
        }
        let background = LLMRequest(collectStream: collect, priority: .background, admission: controller)

        let foreground = await controller.acquireForeground()
        let task = Task { await background.collectDetailedAsync(messages: [], smart: false) }
        await yieldUntil { calls.value > 0 }
        XCTAssertEqual(calls.value, 0, "background ran while foreground was held")

        await controller.releaseForeground(foreground)
        let result = await task.value
        XCTAssertEqual(result?.text, "done")
        XCTAssertEqual(calls.value, 1)
    }

    func testBackgroundCollectYieldsToForegroundAndResumes() async {
        let controller = LLMAdmissionController()
        let calls = Counter()
        let gate = BlockingGate()
        let collect: LLMRequest.CollectStream = { _, _, _, _ in
            let attempt = calls.increment()
            if attempt == 1 {
                try await gate.blockUntilCancelled()
            }
            return collectedResponse("attempt-\(attempt)")
        }
        let background = LLMRequest(collectStream: collect, priority: .background, admission: controller)
        let task = Task { await background.collectDetailedAsync(messages: [], smart: false) }
        await gate.waitUntilStarted()
        XCTAssertEqual(calls.value, 1)

        // Foreground arrives mid-flight: the background attempt yields, then
        // resumes once foreground settles.
        let foreground = await controller.acquireForeground()
        await controller.releaseForeground(foreground)

        let result = await task.value
        XCTAssertEqual(result?.text, "attempt-2", "background must retry after yielding")
        XCTAssertEqual(calls.value, 2, "background must retry exactly once, not loop or duplicate")
    }

    func testForegroundCollectDoesNotWaitBehindInFlightBackground() async {
        let controller = LLMAdmissionController()
        let gate = BlockingGate()
        let backgroundCollect: LLMRequest.CollectStream = { _, _, _, _ in
            try await gate.blockUntilCancelled()
            return collectedResponse("bg")
        }
        let background = LLMRequest(collectStream: backgroundCollect, priority: .background, admission: controller)
        let backgroundTask = Task { await background.collectDetailedAsync(messages: [], smart: false) }
        await gate.waitUntilStarted()

        let foregroundCalls = Counter()
        let foregroundCollect: LLMRequest.CollectStream = { _, _, _, _ in
            foregroundCalls.increment()
            return collectedResponse("fg")
        }
        let foreground = LLMRequest(collectStream: foregroundCollect, priority: .foreground, admission: controller)
        let result = await foreground.collectDetailedAsync(messages: [], smart: false)
        XCTAssertEqual(result?.text, "fg")
        XCTAssertEqual(foregroundCalls.value, 1)

        backgroundTask.cancel()
        _ = await backgroundTask.value
    }

    // MARK: - Cancellation

    func testCancellingCollectStopsInFlightWorkPromptly() async {
        let controller = LLMAdmissionController()
        let gate = BlockingGate()
        let collect: LLMRequest.CollectStream = { _, _, _, _ in
            try await gate.blockUntilCancelled()
            return collectedResponse("never")
        }
        let request = LLMRequest(collectStream: collect, priority: .foreground, admission: controller)
        let task = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        await gate.waitUntilStarted()

        request.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled collect must return nothing")
        let active = await controller.foregroundActive
        XCTAssertFalse(active, "a cancelled collect must release its foreground slot")
    }

    func testCancelledQueuedBackgroundCollectLeavesSchedulerHealthy() async {
        let controller = LLMAdmissionController()
        let calls = Counter()
        let collect: LLMRequest.CollectStream = { _, _, _, _ in
            calls.increment()
            return collectedResponse("ok")
        }
        let background = LLMRequest(collectStream: collect, priority: .background, admission: controller)
        let foreground = await controller.acquireForeground()
        let task = Task { await background.collectDetailedAsync(messages: [], smart: false) }
        await yieldUntil { calls.value > 0 }
        XCTAssertEqual(calls.value, 0)

        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)

        await controller.releaseForeground(foreground)
        // The same request is reusable and the scheduler still admits background.
        let result = await background.collectDetailedAsync(messages: [], smart: false)
        XCTAssertEqual(result?.text, "ok")
        XCTAssertEqual(calls.value, 1)
    }

    func testSingleFlightCancelsPreviousCollect() async {
        let controller = LLMAdmissionController()
        let gate = BlockingGate()
        let calls = Counter()
        let collect: LLMRequest.CollectStream = { _, _, _, _ in
            let attempt = calls.increment()
            if attempt == 1 {
                try await gate.blockUntilCancelled()
                return collectedResponse("first")
            }
            return collectedResponse("second")
        }
        let request = LLMRequest(collectStream: collect, priority: .foreground, admission: controller)
        let first = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        await gate.waitUntilStarted()

        // A second collect on the same request cancels the first (single-flight).
        let second = await request.collectDetailedAsync(messages: [], smart: false)
        let firstResult = await first.value
        XCTAssertNil(firstResult, "the superseded collect must be cancelled")
        XCTAssertEqual(second?.text, "second")
    }

    func testOldCompletionCannotClearNewCollectOwnership() async {
        let controller = LLMAdmissionController()
        let firstGate = BlockingGate()
        let secondGate = BlockingGate()
        let calls = Counter()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            if calls.increment() == 1 {
                try await firstGate.blockUntilCancelled()
            } else {
                try await secondGate.blockUntilCancelled()
            }
            return collectedResponse("cancelled")
        }, admission: controller)
        let first = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        await firstGate.waitUntilStarted()
        let second = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        await secondGate.waitUntilStarted()
        _ = await first.value
        XCTAssertTrue(request.isActive, "an old completion must not clear the new flight")
        request.cancel()
        let secondResult = await second.value
        XCTAssertNil(secondResult)
        XCTAssertFalse(request.isActive)
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
    }

    func testBackgroundRetryKeepsItsOriginalProviderRoute() async {
        let controller = LLMAdmissionController()
        let resolutions = Counter()
        let calls = Counter()
        let gate = BlockingGate()
        let client = LLMClient(providerResolver: {
            LLMProviderConfig(
                id: "test", displayName: "Test",
                baseURL: URL(string: "https://example.invalid/v1")!,
                model: "model-\(resolutions.increment())", supportsThinking: false,
                apiKey: { "" }
            )
        })
        let request = LLMRequest(client: client, collectStream: { _, _, route, _ in
            if calls.increment() == 1 { try await gate.blockUntilCancelled() }
            return collectedResponse(route?.provider.model ?? "missing")
        }, priority: .background, admission: controller)
        let task = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        await gate.waitUntilStarted()
        let foreground = await controller.acquireForeground()
        await controller.releaseForeground(foreground)
        let result = await task.value
        XCTAssertEqual(result?.text, "model-1")
        XCTAssertEqual(resolutions.value, 1)
        XCTAssertEqual(calls.value, 2)
    }

    func testDirectToolStreamHoldsAndReleasesForeground() async throws {
        let controller = LLMAdmissionController()
        let request = LLMRequest(toolStream: { _, _, _, _, _, _ in
            let active = await controller.foregroundActive
            XCTAssertTrue(active)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }, admission: controller)
        _ = try await request.streamWithTools(
            messages: [], toolsJSON: nil, smart: false, onContent: { _ in }
        )
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
        XCTAssertFalse(request.isActive)
    }

    func testThrowingCollectPreservesProviderErrorAndReleasesLease() async {
        let controller = LLMAdmissionController()
        let request = LLMRequest(collectStream: { _, _, _, _ in
            throw LLMError.unauthorized
        }, admission: controller)
        do {
            _ = try await request.collectDetailedThrowingAsync(messages: [], smart: false)
            XCTFail("provider failure was swallowed")
        } catch LLMError.unauthorized {
            // The exact provider error, not cancellation, nil or empty output.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
        XCTAssertFalse(request.isActive)
        let compatibility = await request.collectDetailedAsync(messages: [], smart: false)
        XCTAssertNil(compatibility, "optional callers retain their previous failure contract")
    }

    func testThrowingCollectReportsForegroundBusyAfterSixPreemptions() async {
        let controller = LLMAdmissionController()
        let calls = Counter()
        let gates = (0..<LLMRequest.backgroundPreemptionAttempts).map { _ in BlockingGate() }
        let request = LLMRequest(collectStream: { _, _, _, _ in
            let index = calls.increment() - 1
            guard index < gates.count else { throw LLMError.badResponse }
            try await gates[index].blockUntilCancelled()
            return collectedResponse("cancelled")
        }, priority: .background, admission: controller)
        let task = Task { try await request.collectDetailedThrowingAsync(messages: [], smart: false) }
        for gate in gates {
            await gate.waitUntilStarted()
            let foreground = await controller.acquireForeground()
            await controller.releaseForeground(foreground)
        }
        do {
            _ = try await task.value
            XCTFail("six foreground yields must return an explicit retryable failure")
        } catch LLMRequestSchedulingError.foregroundBusy {
            // Expected: distinct from a provider error and from cancellation.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(calls.value, LLMRequest.backgroundPreemptionAttempts)
        XCTAssertFalse(request.isActive)
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
    }

    func testSixPreemptionsFailExplicitlyAndReleaseAllState() async {
        let controller = LLMAdmissionController()
        let calls = Counter()
        let gates = (0..<LLMRequest.backgroundPreemptionAttempts).map { _ in BlockingGate() }
        let request = LLMRequest(collectStream: { _, _, _, _ in
            let index = calls.increment() - 1
            guard index < gates.count else {
                XCTFail("preemption retries exceeded the documented bound")
                return collectedResponse("unexpected")
            }
            try await gates[index].blockUntilCancelled()
            return collectedResponse("cancelled")
        }, priority: .background, admission: controller)
        let task = Task { await request.collectDetailedAsync(messages: [], smart: false) }
        for gate in gates {
            await gate.waitUntilStarted()
            let lease = await controller.acquireForeground()
            await controller.releaseForeground(lease)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(calls.value, LLMRequest.backgroundPreemptionAttempts)
        XCTAssertFalse(request.isActive)
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
        let background = await controller.acquireBackground()
        XCTAssertNotNil(background)
    }

    @MainActor
    func testMultiRoundToolLoopKeepsForegroundThroughToolAndReleases() async {
        let controller = LLMAdmissionController()
        let rounds = Counter()
        let tools = Counter()
        let tool = LLMToolDefinition(name: "fixture_tool", description: "Fixture", parameters: [:], execute: { _ in
            let active = await controller.foregroundActive
            XCTAssertTrue(active, "the turn lease must cover tool execution")
            tools.increment()
            return "fixture"
        }, runningStatus: nil)
        let request = LLMRequest(toolStream: { _, _, _, _, _, _ in
            let active = await controller.foregroundActive
            XCTAssertTrue(active)
            if rounds.increment() == 1 {
                return LLMClient.StreamResult(toolCalls: [
                    LLMToolCall(id: "fixture", type: "function", function: .init(name: "fixture_tool", arguments: "{}"))
                ], finishReason: "tool_calls", reasoningCharacters: 0)
            }
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }, admission: controller)
        let loop = ToolLoop(request: request, makeToolExecutor: { _, _ in ToolExecutor(tools: [tool]) })
        await loop.run(conversation: [], toolsJSON: nil, smart: false, onEvent: { _ in })
        XCTAssertEqual(rounds.value, 2)
        XCTAssertEqual(tools.value, 1)
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
    }

    @MainActor
    func testCancellingDuringToolReleasesTurnLeaseAndSkipsNextRound() async {
        let controller = LLMAdmissionController()
        let gate = BlockingGate()
        let rounds = Counter()
        let tool = LLMToolDefinition(name: "fixture_tool", description: "Fixture", parameters: [:], execute: { _ in
            try? await gate.blockUntilCancelled()
            return "cancelled fixture"
        }, runningStatus: nil)
        let request = LLMRequest(toolStream: { _, _, _, _, _, _ in
            rounds.increment()
            return LLMClient.StreamResult(toolCalls: [
                LLMToolCall(id: "fixture", type: "function", function: .init(name: "fixture_tool", arguments: "{}"))
            ], finishReason: "tool_calls", reasoningCharacters: 0)
        }, admission: controller)
        let loop = ToolLoop(request: request, makeToolExecutor: { _, _ in ToolExecutor(tools: [tool]) })
        let task = Task { await loop.run(conversation: [], toolsJSON: nil, smart: false, onEvent: { _ in }) }
        await gate.waitUntilStarted()
        task.cancel()
        await task.value
        XCTAssertEqual(rounds.value, 1)
        let active = await controller.foregroundActive
        XCTAssertFalse(active)
        XCTAssertFalse(request.isActive)
    }

    // MARK: - Callback stream participates

    func testCallbackStreamAcquiresAndReleasesAdmission() async {
        let controller = LLMAdmissionController()
        // Empty key: the client's stream fails immediately without any network.
        let provider = LLMProviderConfig(
            id: "test",
            displayName: "Test",
            baseURL: URL(string: "https://example.invalid/v1")!,
            model: "none",
            supportsThinking: false,
            apiKey: { "" }
        )
        let request = LLMRequest(client: LLMClient(provider: provider), priority: .foreground, admission: controller)
        let epochBefore = await controller.currentForegroundEpoch

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request.stream(
                messages: [LLMMessage(role: "user", content: "hi")],
                smart: false,
                onDelta: { _ in },
                onError: { _, _ in },
                onComplete: { continuation.resume() }
            )
        }

        let epochAfter = await controller.currentForegroundEpoch
        XCTAssertEqual(epochAfter, epochBefore + 1, "stream() must acquire a foreground slot")
        let active = await controller.foregroundActive
        XCTAssertFalse(active, "stream() must release its slot on completion")

        let background = await controller.acquireBackground()
        XCTAssertNotNil(background, "the scheduler must be healthy after a callback stream")
        await controller.releaseBackground(background!.lease)
    }
}

/// File-scope (not a method) so a `@Sendable` stub can call it without
/// capturing the non-Sendable test case.
private func collectedResponse(_ text: String) -> LLMClient.CollectedResponse {
    LLMClient.CollectedResponse(text: text, finishReason: "stop", reasoningCharacters: 0)
}
