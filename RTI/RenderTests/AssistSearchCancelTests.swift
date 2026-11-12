import HouseChatCore
@testable import RTICore
import XCTest

/// The local vault search ahead of an Ask belongs to the chat it started in.
///
/// These drive a real `LLMController` with a slow stubbed search
/// (`localSearch`), a stub provider stream and a temp thread store. A Stop or
/// `/new` during the search must send nothing and leave no progress entry, and
/// a search that is not cancelled must still send.
@MainActor
final class AssistSearchCancelTests: XCTestCase {
    private var root: URL!
    private var store: ChatThreadStore!

    /// A question the retrieval heuristics always search the vault for.
    private let searchedQuestion = "What did the previous meeting decide?"

    override func setUp() async throws {
        try await super.setUp()
        try RenderProofHarness.prepare()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-assist-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true),
            removeProjections: { _ in VaultLogStore.ProjectionCleanup() }
        ))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Harness

    /// Holds the stubbed search open until the test releases it. The search
    /// ignores cancellation, as the real keyword scan does.
    @MainActor
    private final class SearchGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        private var released = false

        func wait() async {
            calls += 1
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    /// Counts provider calls and, when asked, holds each stream open.
    private final class StreamProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var holding = false
        private var prompts: [String] = []

        var calls: Int {
            lock.withLock { callCount }
        }

        var lastPrompt: String? {
            lock.withLock { prompts.last }
        }

        var isHolding: Bool {
            lock.withLock { holding }
        }

        func hold() {
            lock.withLock { holding = true }
        }

        func release() {
            lock.withLock { holding = false }
        }

        func record(_ prompt: String) {
            lock.withLock {
                callCount += 1
                prompts.append(prompt)
            }
        }
    }

    private func stream(_ probe: StreamProbe) -> LLMRequest.ToolStream {
        { messages, _, _, _, onContent, _ in
            probe.record(messages.last(where: { $0.role == "user" })?.content ?? "")
            onContent("Stub answer")
            while probe.isHolding {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
    }

    private static func route() -> ChatRouteConfiguration {
        let provider = LLMProviderConfig(
            id: "stub",
            displayName: "Stub",
            baseURL: URL(string: "https://stub.invalid/v1")!,
            model: "stub-model",
            supportsThinking: false,
            supportsVision: true,
            apiKey: { "test-key" }
        )
        return ChatRouteConfiguration(
            provider: provider,
            reasoning: .fast,
            imageRoute: .none,
            imageCount: 0,
            selection: ChatModelSelection(providerId: "stub", reasoning: .fast)
        )
    }

    private func makeController(probe: StreamProbe, gate: SearchGate) -> LLMController {
        let controller = LLMController(
            request: LLMRequest(toolStream: stream(probe)),
            chatStore: store,
            storeIsInjected: true,
            sessionIDProvider: { nil },
            routeResolver: { _, _, _ in .success(Self.route()) },
            callTypeStore: .inMemory(),
            turnLogger: { _ in },
            ambientScreenProvider: { nil }
        )
        controller.localSearch = { query, scope, policy in
            await gate.wait()
            return VaultRetrieval.localResponse(
                query: query,
                scopeRelativePath: scope,
                results: [],
                inScope: false,
                elapsedMS: 1,
                zeroResultPolicy: policy,
                status: .noMatch
            )
        }
        return controller
    }

    /// Wait until `condition` holds, yielding the main actor between checks.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Let any task that a release woke run to its end.
    private func settle() async throws {
        for _ in 0 ..< 20 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Tests

    func testStopDuringSearchSendsNothingAndClearsTheProgressEntry() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer { controller.cancel() }

        controller.sendAskAnything(searchedQuestion)
        try await waitUntil("the search to start") { gate.calls == 1 }
        XCTAssertFalse(controller.progressStatus.isEmpty, "The search shows its progress entry")

        controller.cancel()
        XCTAssertTrue(controller.progressStatus.isEmpty, "Stop removes 'Searching the vault…'")
        XCTAssertTrue(controller.entries.isEmpty, "The unsent question goes with its placeholder")
        XCTAssertEqual(controller.pendingDraftRestore, searchedQuestion, "The unsent question goes back to the composer")
        XCTAssertFalse(controller.streaming)

        gate.release()
        try await settle()
        XCTAssertEqual(probe.calls, 0, "A stopped search must not send")
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(controller.progressStatus.isEmpty)
    }

    func testNewChatDuringSearchLeavesTheNewChatEmpty() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer { controller.cancel() }

        controller.sendAskAnything(searchedQuestion)
        try await waitUntil("the search to start") { gate.calls == 1 }

        controller.newChat()
        gate.release()
        try await settle()

        XCTAssertEqual(probe.calls, 0, "The old search must not answer into the new chat")
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(controller.progressStatus.isEmpty)
        XCTAssertFalse(controller.streaming)
    }

    /// Only a user Stop hands the unsent question back. `/new`, the
    /// upgrade-end clear (both `newChat`), a session start (`resetMemory`) and
    /// a resumed thread cancel the search without restoring it.
    func testConversationResetsDuringSearchNeverRestoreTheQuestion() async throws {
        let saved = try await store.thread(id: "saved", title: "Saved fixture", surface: .rtiCopilot,
                                           session: nil, appVersion: "fixture")
        _ = try await store.appendTurn(to: saved, turn: .init(text: "Saved question"))
        let resets: [(String, (LLMController) async -> Void)] = [
            ("newChat", { $0.newChat() }),
            ("resetMemory", { $0.resetMemory() }),
            ("resumeChat", { await $0.resumeChat(id: "saved") }),
        ]
        for (name, reset) in resets {
            let probe = StreamProbe()
            let gate = SearchGate()
            let controller = makeController(probe: probe, gate: gate)
            controller.sendAskAnything(searchedQuestion)
            try await waitUntil("the search to start (\(name))") { gate.calls == 1 }

            await reset(controller)
            XCTAssertNil(controller.pendingDraftRestore, "\(name) must not put the old question back")
            gate.release()
            try await settle()
            XCTAssertNil(controller.pendingDraftRestore, "\(name): the stale search must not restore it later")
            XCTAssertEqual(probe.calls, 0, "\(name): the old search must not send")
            XCTAssertTrue(controller.progressStatus.isEmpty)
            controller.cancel()
        }
    }

    func testAssistAfterStopSurvivesTheStaleSearchReturning() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer {
            probe.release()
            controller.cancel()
        }

        controller.sendAskAnything(searchedQuestion)
        try await waitUntil("the search to start") { gate.calls == 1 }
        controller.cancel()

        probe.hold()
        controller.sendAssist()
        try await waitUntil("the Assist stream to start") { probe.calls == 1 }
        XCTAssertTrue(controller.streaming)
        let assistAnswer = try XCTUnwrap(controller.streamingEntryID)

        gate.release()
        try await settle()

        XCTAssertEqual(probe.calls, 1, "The stale search must not start a second send")
        XCTAssertTrue(controller.streaming, "The Assist stream is still running")
        XCTAssertEqual(controller.streamingEntryID, assistAnswer)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.progressStatus.isEmpty)

        probe.release()
        try await waitUntil("the Assist stream to finish") { !controller.streaming }
        XCTAssertEqual(controller.entries.filter { $0.role == "user" }.map(\.action), ["Assist"])
        XCTAssertTrue(controller.entries.contains { $0.id == assistAnswer && $0.text == "Stub answer" })
    }

    func testUncancelledSearchStillSends() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer { controller.cancel() }

        controller.sendAskAnything(searchedQuestion)
        try await waitUntil("the search to start") { gate.calls == 1 }
        gate.release()

        try await waitUntil("the answer to finish") { probe.calls == 1 && !controller.streaming }
        XCTAssertTrue(probe.lastPrompt?.contains(searchedQuestion) == true, "The question reaches the provider")
        XCTAssertTrue(controller.progressStatus.isEmpty)
        XCTAssertEqual(controller.entries.filter { $0.role == "user" }.map(\.text), [searchedQuestion])
        XCTAssertEqual(controller.entries.last?.text, "Stub answer")
        XCTAssertNil(controller.lastError)
    }

    func testSendWhileBusyIsRefusedVisibly() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer {
            gate.release()
            controller.cancel()
        }

        controller.sendAskAnything(searchedQuestion)
        try await waitUntil("the search to start") { gate.calls == 1 }
        XCTAssertTrue(controller.streaming)

        controller.sendAssist()
        XCTAssertEqual(controller.lastError, LLMController.busySendMessage, "Assist during a search says why it did not send")
        XCTAssertNil(controller.lastErrorTurnID, "The notice belongs to no turn, so the thread draws it under the chat")
        XCTAssertEqual(probe.calls, 0)

        controller.lastError = nil
        controller.sendAskAnything("another question")
        XCTAssertEqual(controller.lastError, LLMController.busySendMessage, "A second Ask during a search is refused visibly too")
    }

    func testBusyNoticeLeavesWhenTheRunningTurnEnds() async throws {
        let probe = StreamProbe()
        let gate = SearchGate()
        let controller = makeController(probe: probe, gate: gate)
        defer {
            probe.release()
            controller.cancel()
        }

        probe.hold()
        controller.sendAssist()
        try await waitUntil("the Assist stream to start") { probe.calls == 1 }
        controller.sendAssist()
        XCTAssertEqual(controller.lastError, LLMController.busySendMessage)

        probe.release()
        try await waitUntil("the Assist stream to finish") { !controller.streaming }
        XCTAssertNil(controller.lastError, "Once the turn is done, RTI no longer says it is still working")

        probe.hold()
        controller.sendAssist()
        try await waitUntil("the second Assist stream to start") { probe.calls == 2 }
        controller.sendAssist()
        XCTAssertEqual(controller.lastError, LLMController.busySendMessage)
        controller.cancel()
        XCTAssertNil(controller.lastError, "Stop clears the busy notice too")
    }

    // MARK: - The transcript upgrade's chat reset

    private func seededTurn() -> [ChatEntry] {
        [
            ChatEntry(role: "user", text: "q", action: "Assist", contextUsed: false, screenContextUsed: false),
            ChatEntry(role: "assistant", text: "a", action: nil, contextUsed: false, screenContextUsed: false),
        ]
    }

    func testUpgradeEndClearsOnlyAnUntouchedIdleChat() {
        let controller = makeController(probe: StreamProbe(), gate: SearchGate())
        controller.seedForRenderProof(entries: seededTurn())
        let mark = SessionCoordinator.UpgradeChatMark(controller)
        XCTAssertTrue(SessionCoordinator.shouldClearChatAfterUpgrade(mark: mark, llm: controller),
                      "An untouched, idle chat is cleared for the next call")

        controller.streaming = true
        XCTAssertFalse(SessionCoordinator.shouldClearChatAfterUpgrade(mark: mark, llm: controller),
                       "A chat streaming during .upgrading is not cleared")
        let busyMark = SessionCoordinator.UpgradeChatMark(controller)
        controller.streaming = false
        XCTAssertFalse(SessionCoordinator.shouldClearChatAfterUpgrade(mark: busyMark, llm: controller),
                       "An answer that was running at Stop and has finished is not cleared")

        let saved = controller.entries
        controller.entries = seededTurn()
        XCTAssertEqual(controller.entries.count, mark.entryCount)
        XCTAssertFalse(SessionCoordinator.shouldClearChatAfterUpgrade(mark: mark, llm: controller),
                       "A regenerated turn keeps the count but is still a change")
        controller.entries = saved

        controller.generation &+= 1
        XCTAssertFalse(SessionCoordinator.shouldClearChatAfterUpgrade(mark: mark, llm: controller),
                       "A chat opened after Stop is not cleared")
    }

    /// Drives the coordinator's real `.upgrading` -> `.done` path with a
    /// held stub upgrade.
    private func runUpgrade(
        llm: LLMController,
        whileUpgrading: () async throws -> Void
    ) async throws {
        let coordinator = SessionCoordinator.shared
        defer { coordinator.endUpgradePhaseForProof() }
        let upgradeGate = SearchGate()
        let task = coordinator.runUpgradePhaseForProof(sessionId: "proof-\(UUID().uuidString)", llm: llm) {
            await upgradeGate.wait()
            return nil
        }
        XCTAssertEqual(coordinator.phase, .upgrading)
        try await waitUntil("the upgrade to start") { upgradeGate.calls == 1 }
        try await whileUpgrading()
        upgradeGate.release()
        await task.value
        XCTAssertEqual(coordinator.phase, .done)
    }

    func testUpgradeEndClearsAnIdleUntouchedChat() async throws {
        let controller = makeController(probe: StreamProbe(), gate: SearchGate())
        controller.seedForRenderProof(entries: seededTurn())
        try await runUpgrade(llm: controller) {}
        XCTAssertTrue(controller.entries.isEmpty, "The chat resets for the next call")
    }

    func testUpgradeEndKeepsAnAnswerThatWasStreamingAtStop() async throws {
        let probe = StreamProbe()
        let controller = makeController(probe: probe, gate: SearchGate())
        defer {
            probe.release()
            controller.cancel()
        }
        probe.hold()
        controller.sendAssist()
        try await waitUntil("the Assist stream to start") { probe.calls == 1 }
        let answer = try XCTUnwrap(controller.streamingEntryID)

        try await runUpgrade(llm: controller) {
            probe.release()
            try await waitUntil("the answer to finish during the upgrade") { !controller.streaming }
        }
        XCTAssertTrue(controller.entries.contains { $0.id == answer && $0.text == "Stub answer" },
                      "The answer the user is reading stays on screen")
    }

    func testUpgradeEndKeepsAnAnswerStillStreaming() async throws {
        let probe = StreamProbe()
        let controller = makeController(probe: probe, gate: SearchGate())
        defer {
            probe.release()
            controller.cancel()
        }
        try await runUpgrade(llm: controller) {
            probe.hold()
            controller.sendAssist()
            try await waitUntil("the Assist stream to start") { probe.calls == 1 }
        }
        XCTAssertTrue(controller.streaming, "The upgrade's end does not cut off a running answer")
        XCTAssertEqual(controller.entries.count, 2)
    }

    func testUpgradeEndKeepsARegeneratedAnswer() async throws {
        let probe = StreamProbe()
        let controller = makeController(probe: probe, gate: SearchGate())
        defer { controller.cancel() }
        controller.seedForRenderProof(entries: seededTurn())
        let oldAnswer = try XCTUnwrap(controller.entries.last?.id)

        try await runUpgrade(llm: controller) {
            controller.regenerate(assistantID: oldAnswer)
            try await waitUntil("the regenerated answer to finish") { probe.calls == 1 && !controller.streaming }
            XCTAssertEqual(controller.entries.count, 2, "Regenerate keeps the count")
        }
        XCTAssertEqual(controller.entries.last?.text, "Stub answer", "The regenerated answer stays on screen")
    }
}
