import HouseChatCore
import HouseChatDocuments
import RTICore
import XCTest

/// The real runtime send path, not a helper harness.
///
/// These drive an actual `LLMController` instance with an injected temp
/// `ChatThreadStore`, a stub `LLMRequest` stream (no network, no credentials),
/// an injected route, an injected session id, and a no-op turn logger. Nothing
/// here touches the live vault, the app's real Application Support folder, a
/// provider, or a screenshot.
@MainActor
final class ChatRuntimeIntegrationTests: XCTestCase {

    private var root: URL!
    private var store: ChatThreadStore!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true),
            // A temp remover: the delete path must never resolve the live vault
            // config from a test.
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

    /// A thread-safe counter for the stub stream.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A mutable session id, so a test can start standalone and then record.
    private final class SessionBox: @unchecked Sendable {
        var id: String?
        init(_ id: String?) { self.id = id }
    }

    private func textStream(_ text: String = "Stub answer") -> LLMRequest.ToolStream {
        { _, _, _, _, onContent, _ in
            onContent(text)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
    }

    private func countingStream(_ counter: Counter, text: String = "Stub answer") -> LLMRequest.ToolStream {
        { _, _, _, _, onContent, _ in
            counter.increment()
            onContent(text)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
    }

    private static func route(imageCount: Int) -> ChatRouteConfiguration {
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
            imageRoute: imageCount > 0 ? .cloudInline : .none,
            imageCount: imageCount,
            selection: ChatModelSelection(providerId: "stub", reasoning: .fast)
        )
    }

    private func makeController(
        sessionBox: SessionBox = SessionBox(nil),
        routeResolver: (@MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker>)? = nil,
        makeToolExecutor: (@MainActor (Bool, Bool) -> ToolExecutor)? = nil,
        modeStore: ModeStore? = nil,
        turnLogger: ((VaultLogStore.TurnRecord) -> Void)? = nil,
        stream: @escaping LLMRequest.ToolStream
    ) -> LLMController {
        let request = LLMRequest(toolStream: stream)
        return LLMController(
            request: request,
            chatStore: store,
            storeIsInjected: true,
            sessionIDProvider: { sessionBox.id },
            routeResolver: routeResolver ?? { _, imageCount, _ in .success(Self.route(imageCount: imageCount)) },
            makeToolExecutor: makeToolExecutor,
            modeStore: modeStore ?? .inMemory(),
            turnLogger: turnLogger ?? { _ in }
        )
    }

    /// Poll the temp store until it holds at least `expected` turns.
    private func waitForStoredTurns(_ expected: Int, timeout: TimeInterval = 8) async throws -> ConversationRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let summary = try await store.summaries().first {
                let record = try await store.load(id: summary.id)
                if record.turns.count >= expected { return record }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(expected) stored turns")
        throw ChatRuntimeTestTimeout()
    }

    private struct ChatRuntimeTestTimeout: Error {}

    private func pdfFixture() -> ExternalDocumentAttachment {
        ExternalDocumentAttachment.fixture(name: "report.pdf", text: "The number is 42.", kind: .pdf)
    }

    // MARK: - Defect 1 & 6: per-attachment bytes

    func testAttachedImagePersistsItsOwnBytesNotThePendingScreenshot() async throws {
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0x11, 0x22, 0x33, 0x44])
        let normalized = DocumentImageBytes(
            data: Data([0x99, 0x88, 0x77]),
            mimeType: "image/png",
            pixelWidth: 2,
            pixelHeight: 2
        )
        let attachment = ExternalDocumentAttachment(
            name: "photo.png",
            text: "A photo of the number 42.",
            path: "/tmp/photo.png",
            kind: .screen,
            byteCount: original.count,
            pageCount: nil,
            wasCut: false,
            originalBytes: original,
            normalizedImage: normalized,
            document: ExtractedDocument.flat(
                kind: .image,
                kindLabel: "Image",
                name: "photo.png",
                text: "A photo of the number 42."
            )
        )
        let controller = makeController(stream: textStream())
        // A pending screenshot that must NOT be substituted for the file's bytes.
        controller.attachScreenContext("unrelated OCR", image: Data([0x01, 0x02, 0x03]))

        controller.sendAskAnything("what is in this image?", attachments: [attachment])
        let record = try await waitForStoredTurns(2)
        let userTurn = try XCTUnwrap(record.turns.first { $0.role == .user })
        let savedImage = try XCTUnwrap(userTurn.attachments.first { $0.kind == .image })
        XCTAssertEqual(savedImage.contentHash, SHA256Digest.hex(original))
        XCTAssertEqual(savedImage.name, "photo.png")

        let retained = try await store.retainedAttachments(id: record.id)
        let image = try XCTUnwrap(retained.first { $0.kind == .image })
        XCTAssertEqual(image.originalBytes, original, "the file's own bytes must survive, not the screenshot's")
        // The pending screenshot keeps its own distinct bytes.
        let screen = try XCTUnwrap(userTurn.attachments.first { $0.kind == .screenshot })
        XCTAssertEqual(screen.contentHash, SHA256Digest.hex(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - Defect 7: image presence alone yields a saved screenshot

    func testScreenshotWithNoOCRIsStillSaved() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
        let controller = makeController(stream: textStream())
        // Image, no OCR text at all.
        controller.attachScreenContext("", image: jpeg)
        // A text source keeps the turn source-gated (no vault search).
        controller.sendAskAnything("What is this about?", attachments: [pdfFixture()])

        let record = try await waitForStoredTurns(2)
        let userTurn = try XCTUnwrap(record.turns.first { $0.role == .user })
        let savedScreen = try XCTUnwrap(userTurn.attachments.first { $0.kind == .screenshot })
        XCTAssertEqual(savedScreen.contentHash, SHA256Digest.hex(jpeg))

        let retained = try await store.retainedAttachments(id: record.id)
        let screen = try XCTUnwrap(retained.first { $0.kind == .screenshot })
        XCTAssertEqual(screen.originalBytes, jpeg)
    }

    // MARK: - Defect 2: a follow-up stays source-gated

    func testFollowUpAfterAnAttachmentStaysSourceGated() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything("what number is in this file?", attachments: [pdfFixture()])
        _ = try await waitForStoredTurns(2)

        // No new attachment: the retained source must still gate the turn, so
        // the model is not handed a source-less question with the vault open.
        controller.sendAskAnything("and what else?")
        let record = try await waitForStoredTurns(4)
        let userTurns = record.turns.filter { $0.role == .user }
        XCTAssertEqual(userTurns.count, 2)
        let receipt = try XCTUnwrap(userTurns[1].request)
        XCTAssertEqual(receipt.extra["externalRetrieval"]?.boolValue, false)
        XCTAssertGreaterThan(receipt.context?.sourceCharacters ?? 0, 0)
    }

    // MARK: - Defect 9: a local turn is not regenerated as a prompt

    func testLocalSearchTurnIsNotRegeneratedAsAPrompt() async throws {
        let counter = Counter()
        let controller = makeController(stream: countingStream(counter))
#if DEBUG
        let user = ChatEntry(role: "user", text: "/search foo", action: "Search", contextUsed: false, screenContextUsed: false)
        let assistant = ChatEntry(role: "assistant", text: "No hits.", action: nil, contextUsed: false, screenContextUsed: false)
        controller.seedForRenderProof(entries: [user, assistant])
        controller.regenerate(assistantID: assistant.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.count, 0, "a local search must never be sent to the model")
        XCTAssertEqual(controller.entries.count, 2, "the local turn is left untouched")
#else
        throw XCTSkip("seedForRenderProof is DEBUG-only")
#endif
    }

    // MARK: - Defect 4: /new during a send

    func testNewChatBeforeTheFirstWritePreventsAnyThreadBeingCreated() async throws {
        let counter = Counter()
        let controller = makeController(stream: countingStream(counter))
        controller.sendAskAnything("first question", attachments: [pdfFixture()])
        // Runs before the send's Task can get the main actor: the chat identity
        // changes underneath it.
        controller.newChat()
        try await Task.sleep(nanoseconds: 400_000_000)
        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.count, 0, "a send abandoned by /new must not create a thread")
        XCTAssertEqual(counter.count, 0, "it must not start the provider either")
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testNewChatDuringAStreamFilesTheCancelledTurnInItsOwnThread() async throws {
        let entered = Counter()
        let stream: LLMRequest.ToolStream = { _, _, _, _, _, _ in
            entered.increment()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
        let controller = makeController(stream: stream)
        controller.sendAskAnything("first question", attachments: [pdfFixture()])

        let enterDeadline = Date().addingTimeInterval(5)
        while entered.count == 0 && Date() < enterDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(entered.count, 0, "the stub stream must be running before /new")

        // The question is committed; a new chat cancels the in-flight answer.
        controller.newChat()

        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.count, 1, "the cancelled answer stays in its own thread")
        let id = try XCTUnwrap(summaries.first?.id)
        let deadline = Date().addingTimeInterval(5)
        var cancelled: TurnRecord?
        while Date() < deadline {
            let record = try await store.load(id: id)
            if record.turns.last?.request?.status == .cancelled {
                cancelled = record.turns.last
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let last = try XCTUnwrap(cancelled, "the interrupted answer must be filed as cancelled")
        XCTAssertEqual(last.role, .assistant)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    // MARK: - Defect 3: per-turn session links

    func testRecordingSessionLinksOnlyTheTurnsItOwns() async throws {
        let box = SessionBox(nil)
        let controller = makeController(sessionBox: box, stream: textStream())
        // First turn: standalone, no recording.
        controller.sendAskAnything("first standalone question", attachments: [pdfFixture()])
        _ = try await waitForStoredTurns(2)

        // A recording starts; the same chat continues.
        box.id = "session-abc"
        controller.sendAskAnything("second question during the recording", attachments: [pdfFixture()])
        let record = try await waitForStoredTurns(4)

        let mine = await store.sessionChatProjection(linkedToSession: "session-abc")
        let projected = try XCTUnwrap(mine.threads.first)
        XCTAssertEqual(projected.turns.count, 2, "only the recording's own turn and its answer")
        let other = await store.sessionChatProjection(linkedToSession: "some-other-session")
        XCTAssertTrue(other.threads.isEmpty, "a standalone turn is never claimed by a guessed session")

        let linkedTurns = record.turns.filter { $0.sessionLinks.contains { $0.id == "session-abc" } }
        XCTAssertEqual(linkedTurns.count, 2)
    }

    // MARK: - Dated library seed: the controller gets draft + source

    func testDatedSeedSetsDraftAndSourceWithoutSending() async throws {
        let counter = Counter()
        let controller = makeController(stream: countingStream(counter))
        let entry = ChatLibraryDatedSeed.Entry(
            line: 2,
            day: "2026-09-12",
            stamp: "2026-09-12T07:04:00Z",
            timeText: "07:04",
            action: "Ask",
            mode: nil,
            inSession: true,
            question: "what happened?",
            answer: "it rained",
            sources: [],
            tools: []
        )
        let seed = ChatLibraryDatedSeed(
            id: "legacy-entry-2026-09-12-2",
            day: "2026-09-12",
            scope: .entry,
            title: "12 Sep 2026 · 07:04",
            sourcePath: "/vault/turns/2026-09-12.jsonl",
            entries: [entry],
            sourceText: ChatLibraryDatedSeed.sourceText(
                entries: [entry],
                heading: "Dated entry, 12 Sep 2026 · 07:04",
                orientation: "A dated log, not a saved chat."
            ),
            prompt: "About this dated entry (12 Sep 2026 · 07:04): "
        )

        controller.applyDatedChatSeed(seed)
        XCTAssertEqual(controller.pendingDraftRestore, seed.prompt, "the seed's prompt is left editable")
        XCTAssertTrue(controller.entries.isEmpty, "seeding starts a fresh chat")
        XCTAssertEqual(counter.count, 0, "seeding never sends")

        // The next send carries the recorded text as its exact source.
        controller.sendAskAnything(seed.prompt + "did it rain?")
        let record = try await waitForStoredTurns(2)
        let userTurn = try XCTUnwrap(record.turns.first { $0.role == .user })
        let savedSource = try XCTUnwrap(userTurn.attachments.first)
        XCTAssertEqual(savedSource.kind, .markdown)
        XCTAssertEqual(savedSource.contentHash, SHA256Digest.hex(Data(seed.sourceText.utf8)))
    }

    // MARK: - Defect 10: delete cleans owned projections through the injected remover

    func testDeleteUsesTheInjectedProjectionRemover() async throws {
        // A remover that reports a failure: the delete must surface it rather
        // than silently claim a complete clean-up, and must never reach the
        // live vault.
        let failingStore = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("fail-assets", isDirectory: true),
            threads: root.appendingPathComponent("fail-threads", isDirectory: true),
            removeProjections: { _ in VaultLogStore.ProjectionCleanup(failures: ["projection boom"]) }
        ))
        let conversation = try await failingStore.thread(
            id: "delete-me", title: nil, surface: .rtiCopilot, session: nil, appVersion: "test"
        )
        _ = try await failingStore.appendTurn(
            to: conversation,
            turn: ChatThreadStore.SubmittedTurn(text: "hello", role: .user)
        )
        do {
            _ = try await failingStore.delete(id: "delete-me")
            XCTFail("a projection failure must be reported")
        } catch let error as ChatThreadStoreError {
            guard case let .projectionCleanupFailed(id, failures) = error else {
                XCTFail("unexpected error \(error)")
                return
            }
            XCTAssertEqual(id, "delete-me")
            XCTAssertEqual(failures, ["projection boom"])
        }
        XCTAssertFalse(failingStore.contains(id: "delete-me"))
    }

    // MARK: - Repair 1: a dated source survives a failed send

    func testDatedSourceIsKeptWhenTheRouteIsBlocked() async throws {
        let blocked: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, _, _ in
            .failure(.missingCredential(providerName: "Stub"))
        }
        let controller = makeController(routeResolver: blocked, stream: textStream())
        let seed = Self.datedSeed()
        controller.applyDatedChatSeed(seed)
        XCTAssertEqual(controller.pendingDatedSourceName, "Dated entry 12 Sep 2026 · 07:04")

        controller.sendAskAnything(seed.prompt + "did it rain?")
        try await Task.sleep(nanoseconds: 200_000_000)

        // The route never ran, so the source and its prompt are still waiting.
        XCTAssertNotNil(controller.pendingDatedSourceName, "a blocked route keeps the dated source")
        XCTAssertEqual(controller.pendingDraftRestore, seed.prompt)
        let summariesAfterBlock = try await store.summaries()
        XCTAssertEqual(summariesAfterBlock.count, 0, "nothing was written")
    }

    // MARK: - Repair 2: the wire images are the sources' own images

    func testRouteAndReceiptCountEverySourceImage() async throws {
        let imageCountBox = ValueBox()
        let resolver: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, imageCount, _ in
            imageCountBox.set(imageCount)
            return .success(Self.route(imageCount: imageCount))
        }
        let controller = makeController(routeResolver: resolver, stream: textStream())
        let image = Self.imageAttachment(name: "one.png", byte: 0xAA)
        let other = Self.imageAttachment(name: "two.png", byte: 0xBB)

        controller.sendAskAnything("what is in these images?", attachments: [image, other])
        let record = try await waitForStoredTurns(2)

        XCTAssertEqual(imageCountBox.get(), 2, "the route froze with both source images")
        let userTurn = try XCTUnwrap(record.turns.first { $0.role == .user })
        let receipt = try XCTUnwrap(userTurn.request)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 2)
        XCTAssertEqual(receipt.extra["imageRoute"]?.stringValue, "cloudInline")
        XCTAssertEqual(userTurn.attachments.filter { $0.kind == .image }.count, 2)
    }

    func testFollowUpRouteCountsTheRetainedImage() async throws {
        let counts = ValueBox()
        let resolver: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, imageCount, _ in
            counts.set(imageCount)
            return .success(Self.route(imageCount: imageCount))
        }
        let controller = makeController(routeResolver: resolver, stream: textStream())
        controller.sendAskAnything("describe this image", attachments: [Self.imageAttachment(name: "one.png", byte: 0xAA)])
        _ = try await waitForStoredTurns(2)

        // The committed image is retained and the composer's own count must see
        // it, so the preview route and the frozen route stay the same.
        XCTAssertEqual(controller.retainedImageCount, 1, "the committed image is retained")
        counts.set(-1)
        controller.sendAskAnything("and what else?")
        _ = try await waitForStoredTurns(4)
        XCTAssertEqual(counts.get(), 1, "the follow-up route counts the retained image, not zero")
    }

    func testAFreshAttachmentTurnWiresOnlyTheFreshSource() async throws {
        let counts = ValueBox()
        let resolver: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, imageCount, _ in
            counts.set(imageCount)
            return .success(Self.route(imageCount: imageCount))
        }
        let controller = makeController(routeResolver: resolver, stream: textStream())
        controller.sendAskAnything("describe A", attachments: [Self.imageAttachment(name: "A.png", byte: 0xAA)])
        _ = try await waitForStoredTurns(2)

        counts.set(-1)
        controller.sendAskAnything("describe B", attachments: [Self.imageAttachment(name: "B.png", byte: 0xBB)])
        let record = try await waitForStoredTurns(4)
        XCTAssertEqual(counts.get(), 1, "a fresh-source turn wires only its own image, never the retained old one")
        let secondUser = record.turns.filter { $0.role == .user }[1]
        let receipt = try XCTUnwrap(secondUser.request)
        XCTAssertEqual(receipt.context?.scope, .currentSource)
        XCTAssertEqual(receipt.context?.historyIncluded, false)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 1)
        XCTAssertEqual(secondUser.attachments.filter { $0.kind == .image }.count, 1)
    }

    func testAComparisonQuestionWiresFreshAndRetained() async throws {
        let counts = ValueBox()
        let resolver: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, imageCount, _ in
            counts.set(imageCount)
            return .success(Self.route(imageCount: imageCount))
        }
        let controller = makeController(routeResolver: resolver, stream: textStream())
        controller.sendAskAnything("describe A", attachments: [Self.imageAttachment(name: "A.png", byte: 0xAA)])
        _ = try await waitForStoredTurns(2)

        counts.set(-1)
        controller.sendAskAnything(
            "compare B with the earlier file",
            attachments: [Self.imageAttachment(name: "B.png", byte: 0xBB)]
        )
        let record = try await waitForStoredTurns(4)
        XCTAssertEqual(counts.get(), 2, "an explicit comparison includes the retained source")
        let secondUser = record.turns.filter { $0.role == .user }[1]
        let receipt = try XCTUnwrap(secondUser.request)
        XCTAssertEqual(receipt.context?.scope, .currentSourceAndHistory)
        XCTAssertEqual(receipt.context?.historyIncluded, true)
    }

    func testABareFollowUpStillUsesTheRetainedArchive() async throws {
        let counts = ValueBox()
        let resolver: @MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker> = { _, imageCount, _ in
            counts.set(imageCount)
            return .success(Self.route(imageCount: imageCount))
        }
        let controller = makeController(routeResolver: resolver, stream: textStream())
        controller.sendAskAnything("describe A", attachments: [Self.imageAttachment(name: "A.png", byte: 0xAA)])
        _ = try await waitForStoredTurns(2)

        counts.set(-1)
        controller.sendAskAnything("and what else?")
        _ = try await waitForStoredTurns(4)
        XCTAssertEqual(counts.get(), 1, "a bare follow-up reads the retained image")
        XCTAssertEqual(controller.retainedImageCount, 1)
    }

    // MARK: - Repair 3: /new stops the whole multi-round send
    func testNewChatStopsTheNextToolRound() async throws {
        let toolRuns = Counter()
        let streamRounds = Counter()
        let pauseTool = LLMToolDefinition(
            name: "pause_tool",
            description: "pauses",
            parameters: [:],
            execute: { _ in
                toolRuns.increment()
                try? await Task.sleep(nanoseconds: 500_000_000)
                return "paused"
            },
            runningStatus: nil
        )
        let factory: @MainActor (Bool, Bool) -> ToolExecutor = { allowsExternal, allowsScreen in
            ToolExecutor(tools: [pauseTool], allowsExternalRetrieval: allowsExternal, allowsScreenTools: allowsScreen)
        }
        let stream: LLMRequest.ToolStream = { _, _, _, _, onContent, _ in
            streamRounds.increment()
            if streamRounds.count == 1 {
                return LLMClient.StreamResult(
                    toolCalls: [LLMToolCall(id: "1", type: "function", function: .init(name: "pause_tool", arguments: "{}"))],
                    finishReason: "tool_calls",
                    reasoningCharacters: 0
                )
            }
            onContent("the second round should never run")
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
        let controller = makeController(makeToolExecutor: factory, stream: stream)
        controller.sendAskAnything("first question", attachments: [pdfFixture()])

        let deadline = Date().addingTimeInterval(5)
        while toolRuns.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(toolRuns.count, 0, "the tool must be running before /new")

        controller.newChat()
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(streamRounds.count, 1, "cancelling the send must stop the next provider round")
        XCTAssertEqual(toolRuns.count, 1, "and the next tool round")
    }

    // MARK: - Repair 7: cleanup survives headings in the answer

    func testRemovingAThreadKeepsTailsAfterHeadingsAndOtherThreads() {
        let text = """
        # RTI vault chat

        <!-- rti-thread-start: thread-a -->
        ## 07:00

        **RTI**

        first line

        ## A heading inside the answer

        kept tail for thread A

        <!-- rti-thread-end: thread-a -->

        <!-- rti-thread-start: thread-b -->
        ## 08:00

        **RTI**

        body for thread B

        <!-- rti-thread-end: thread-b -->

        ## 09:00

        **RTI**

        a legacy block with no markers
        """
        let result = VaultLogStore.removingMarkdownBlocks(threadID: "thread-a", from: text)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(result.text.contains("kept tail for thread A"), "the tail after the heading is gone too")
        XCTAssertFalse(result.text.contains("thread-a"))
        XCTAssertTrue(result.text.contains("body for thread B"))
        XCTAssertTrue(result.text.contains("a legacy block with no markers"))
    }

    func testLegacyMarkdownOrAnUnmatchedMarkerIsNeverDeleted() {
        let legacy = "## 07:00\n\n**RTI**\n\nlegacy body with a ## heading"
        let legacyResult = VaultLogStore.removingMarkdownBlocks(threadID: "thread-a", from: legacy)
        XCTAssertEqual(legacyResult.removed, 0)
        XCTAssertTrue(legacyResult.text.contains("legacy body"))

        let unmatched = "<!-- rti-thread-start: thread-a -->\n## 07:00\n\nbody with no end marker"
        let unmatchedResult = VaultLogStore.removingMarkdownBlocks(threadID: "thread-a", from: unmatched)
        XCTAssertEqual(unmatchedResult.removed, 0, "an unmatched start is not proof of ownership")
        XCTAssertTrue(unmatchedResult.text.contains("body with no end marker"))
    }

    func testJSONLCleanupRemovesOnlyTheOwnedRows() {
        let owned = Self.turnRecordLine(output: "owned", threadID: "thread-a")
        let other = Self.turnRecordLine(output: "other", threadID: "thread-b")
        let legacyLine = "{\"not\":\"a turn\"}"
        let text = [owned, other, legacyLine].joined(separator: "\n")

        let result = VaultLogStore.removingJSONLRows(threadID: "thread-a", from: text)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(result.text.contains(owned))
        XCTAssertTrue(result.text.contains(other))
        XCTAssertTrue(result.text.contains(legacyLine), "a row that does not decode is never guessed at")
    }

    // MARK: - Mode store isolation

    func testInjectedModeStoreIsTheOneTheControllerReads() async throws {
        let log = TurnLogCollector()
        let custom = Mode(
            id: "user.injected",
            name: "Injected Mode",
            systemPrompt: "injected",
            isBuiltin: false,
            createdAt: Date(),
            referenceText: nil
        )
        let controller = makeController(
            modeStore: .inMemory(modes: [custom], activeModeId: "user.injected"),
            turnLogger: { log.append($0) },
            stream: textStream()
        )
        controller.sendSummary()

        let deadline = Date().addingTimeInterval(5)
        while log.count == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            log.modes.first ?? nil,
            "Injected Mode",
            "the controller read the injected mode store, not the live one"
        )
    }

    // MARK: - Fixtures

    private static func datedSeed() -> ChatLibraryDatedSeed {
        let entry = ChatLibraryDatedSeed.Entry(
            line: 2,
            day: "2026-09-12",
            stamp: "2026-09-12T07:04:00Z",
            timeText: "07:04",
            action: "Ask",
            mode: nil,
            inSession: true,
            question: "what happened?",
            answer: "it rained",
            sources: [],
            tools: []
        )
        return ChatLibraryDatedSeed(
            id: "legacy-entry-2026-09-12-2",
            day: "2026-09-12",
            scope: .entry,
            title: "12 Sep 2026 · 07:04",
            sourcePath: "/vault/turns/2026-09-12.jsonl",
            entries: [entry],
            sourceText: ChatLibraryDatedSeed.sourceText(
                entries: [entry],
                heading: "Dated entry, 12 Sep 2026 · 07:04",
                orientation: "A dated log, not a saved chat."
            ),
            prompt: "About this dated entry (12 Sep 2026 · 07:04): "
        )
    }

    private static func imageAttachment(name: String, byte: UInt8) -> ExternalDocumentAttachment {
        ExternalDocumentAttachment(
            name: name,
            text: "An image.",
            path: "/tmp/\(name)",
            kind: .image,
            byteCount: 3,
            pageCount: nil,
            wasCut: false,
            originalBytes: Data([byte, byte, byte]),
            normalizedImage: DocumentImageBytes(
                data: Data([byte, byte]),
                mimeType: "image/png",
                pixelWidth: 2,
                pixelHeight: 2
            ),
            document: ExtractedDocument.flat(kind: .image, kindLabel: "Image", name: name, text: "An image.")
        )
    }

    private static func turnRecordLine(output: String, threadID: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(turnRecord(output: output, threadID: threadID))
        return String(data: data, encoding: .utf8)!
    }

    private static func turnRecord(output: String, threadID: String?) -> VaultLogStore.TurnRecord {
        VaultLogStore.TurnRecord(
            ts: "2026-09-17T07:00:00Z",
            action: "Ask",
            mode: nil,
            provider: "stub",
            model: "stub-model",
            smart: false,
            selectedProvider: "stub",
            selectedModel: nil,
            reasoning: "fast",
            thinkingSent: false,
            imageRoute: "none",
            imageCount: 0,
            toolPolicy: "external",
            inSession: false,
            contextUsed: false,
            screenUsed: false,
            userInput: "question",
            transcriptContext: "",
            output: output,
            latency: nil,
            sources: [],
            toolCalls: nil,
            threadID: threadID,
            turnID: UUID().uuidString
        )
    }
}

/// A tiny lock-protected value for a Sendable test closure.
private final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ newValue: Int) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Collects the turn log records an injected logger receives, so a test can
/// read the mode the controller actually used without touching the vault.
private final class TurnLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [VaultLogStore.TurnRecord] = []
    func append(_ record: VaultLogStore.TurnRecord) { lock.lock(); records.append(record); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    var modes: [String] { lock.lock(); defer { lock.unlock() }; return records.map { $0.mode ?? "" } }
}
