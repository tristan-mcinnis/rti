import HouseChatCore
@testable import RTICore
import XCTest

/// NET-7: an answer still streaming at Stop must reach `chat.md` and the
/// `-rti.md` sidecar once it is filed, not stay cut at what the thread store
/// held at Stop. Drives the real `LLMController` send path with a gated stub
/// stream (no network), a temp thread store and a temp vault config; the
/// archive and sidecar are the real writers.
@MainActor
final class LateChatArchiveTests: XCTestCase {
    private var root: URL!
    private var store: ChatThreadStore!
    private var savedConfigHome: String?
    private let startedAt = Date(timeIntervalSince1970: 1_781_000_000)
    private let sessionID = "invented-late-chat-session"

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-late-chat-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ]).write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)
        store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true),
            removeProjections: { _ in VaultLogStore.ProjectionCleanup() }
        ))
    }

    override func tearDown() async throws {
        if let savedConfigHome {
            setenv("RTI_CONFIG_HOME", savedConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    func testAnswerFinishingAfterStopIsWrittenIntoChatAndSidecar() async throws {
        let gate = StreamGate()
        let controller = makeController(gate: gate)
        defer { controller.cancel() }
        let refresher = LateChatArchiveRefresher(store: { [store] in store })
        controller.sendAskAnything("What did we agree on pricing?")
        try await waitUntil { gate.entered }
        try await waitForStoredTurns(1)

        // Stop a few seconds after Send: the store holds the question only.
        refresher.begin(sessionID: sessionID)
        let directory = try await stop(controller: controller, refresher: refresher)
        XCTAssertFalse(try chat(in: directory).contains("now complete"), "Precondition: Stop saw no answer")
        XCTAssertFalse(try sidecar().contains("now complete"))

        // The provider finishes after Stop.
        gate.open()
        try await waitForStoredTurns(2)
        try await waitUntil { (try? self.sidecar().contains("now complete")) == true }
        await refresher.settled()
        let chatText = try chat(in: directory)
        XCTAssertTrue(chatText.contains("Partial answer, now complete"), chatText)
        XCTAssertTrue(chatText.contains("What did we agree on pricing?"))
        let sidecarText = try sidecar()
        XCTAssertTrue(sidecarText.contains("Partial answer, now complete"), sidecarText)
        XCTAssertTrue(sidecarText.contains("What did we agree on pricing?"), "The question stays with its answer")
    }

    /// The answer lands after the projection was read but before the archive
    /// was written: the refresher remembers it and rewrites once archived.
    func testAnswerFiledBetweenProjectionAndArchiveIsNotMissed() async throws {
        let gate = StreamGate()
        let controller = makeController(gate: gate)
        defer { controller.cancel() }
        let refresher = LateChatArchiveRefresher(store: { [store] in store })
        controller.sendAskAnything("Which city is next?")
        try await waitUntil { gate.entered }
        try await waitForStoredTurns(1)

        refresher.begin(sessionID: sessionID)
        let stale = await store.sessionChatProjection(linkedToSession: sessionID)
        gate.open()
        try await waitForStoredTurns(2)
        try await waitUntil { refresher.target?.filedBeforeArchive == true }
        let directory = try await stop(controller: controller, refresher: refresher, projection: stale)
        await refresher.settled()
        XCTAssertTrue(try chat(in: directory).contains("Partial answer, now complete"))
        XCTAssertTrue(try sidecar().contains("Partial answer, now complete"))
    }

    /// A filed turn of another recording leaves this one's files alone.
    func testOtherRecordingsTurnDoesNotRewrite() {
        let refresher = LateChatArchiveRefresher(store: { [store] in store })
        refresher.begin(sessionID: sessionID)
        refresher.turnFiled(sessionIDs: ["some-other-session"])
        XCTAssertEqual(refresher.target?.filedBeforeArchive, false)
    }

    // MARK: Helpers

    /// What `completeStop` does: archive and sidecar from the projection,
    /// then hand the snapshot to the refresher.
    private func stop(
        controller: LLMController,
        refresher: LateChatArchiveRefresher,
        projection: (threads: [ChatProjectionMarkdown.Thread], unreadable: Int)? = nil
    ) async throws -> URL {
        let read = if let projection {
            projection
        } else {
            await store.sessionChatProjection(linkedToSession: sessionID)
        }
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600),
            transcript: [LiveEntry(speakerId: "self", text: "Invented archived words", startMs: 1000, confidence: 1,
                                   translationStatus: "original", language: "en", sourceLanguage: nil)],
            chat: controller.entries, visualContext: [], notes: [],
            sessionId: sessionID, micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil,
            chatThreads: read.threads, unreadableChatCount: read.unreadable
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        XCTAssertNotNil(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: directory, callType: .client))
        refresher.archived(sessionID: sessionID, snapshot: snapshot, archiveDir: directory, callType: .client)
        return directory
    }

    private func makeController(gate: StreamGate) -> LLMController {
        let provider = LLMProviderConfig(
            id: "stub", displayName: "Stub", baseURL: URL(string: "https://stub.invalid/v1")!,
            model: "stub-model", supportsThinking: false, supportsVision: false, apiKey: { "test-key" }
        )
        let route = ChatRouteConfiguration(provider: provider, reasoning: .fast, imageRoute: .none, imageCount: 0,
                                           selection: ChatModelSelection(providerId: "stub", reasoning: .fast))
        let stream: LLMRequest.ToolStream = { _, _, _, _, onContent, _ in
            onContent("Partial")
            await gate.wait()
            onContent(" answer, now complete")
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
        let id = sessionID
        return LLMController(
            request: LLMRequest(toolStream: stream), chatStore: store, storeIsInjected: true,
            sessionIDProvider: { id }, routeResolver: { _, _, _ in .success(route) },
            callTypeStore: .inMemory(), turnLogger: { _ in }, ambientScreenProvider: { nil }
        )
    }

    private func waitForStoredTurns(_ count: Int) async throws {
        try await waitUntil {
            await self.storedTurnCount() >= count
        }
    }

    private func storedTurnCount() async -> Int {
        guard let summary = try? await store.summaries().first,
              let record = try? await store.load(id: summary.id) else { return 0 }
        return record.turns.filter { $0.role == .user || $0.request?.status == .completed }.count
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 500 {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out")
    }

    private func chat(in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("chat.md"), encoding: .utf8)
    }

    private func sidecar() throws -> String {
        let raw = root.appendingPathComponent("transcripts-raw")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: raw.path).first { $0.hasSuffix("-rti.md") })
        return try String(contentsOf: raw.appendingPathComponent(name), encoding: .utf8)
    }
}

/// Holds the stub stream mid-answer until the test opens it.
private final class StreamGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var didEnter = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var entered: Bool {
        lock.withLock { didEnter }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                didEnter = true
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resume {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}
