import HouseChatCore
import HouseChatDocuments
@testable import RTICore
import XCTest

/// The real controller-to-request boundary for a chat's sources and for the
/// answer that survives Stop, failure and `/new`.
///
/// These drive an actual `LLMController` with an injected temporary
/// `ChatThreadStore`, a stub `LLMRequest` stream (no network, no credentials),
/// an injected route, and a no-op turn logger. `RTI_CONFIG_HOME` points at a
/// temporary folder, so no test can read the live vault config. Nothing here
/// touches the live vault, a provider, a recording or the real Application
/// Support folder.
@MainActor
final class ChatSourceLifecycleTests: XCTestCase {

    private var root: URL!
    private var store: ChatThreadStore!
    private var previousConfigHome: String?

    override func setUp() async throws {
        try await super.setUp()
        previousConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // No live vault config, so any vault lookup a turn performs sees no
        // vault rather than the user's own.
        setenv("RTI_CONFIG_HOME", root.appendingPathComponent("config", isDirectory: true).path, 1)
        store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true),
            removeProjections: { _ in VaultLogStore.ProjectionCleanup() }
        ))
    }

    override func tearDown() async throws {
        if let previousConfigHome {
            setenv("RTI_CONFIG_HOME", previousConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        try? FileManager.default.removeItem(at: root)
        root = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Harness

    private func textStream(_ text: String = "Stub answer") -> LLMRequest.ToolStream {
        { _, _, _, _, onContent, _ in
            onContent(text)
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
    }

    private func route(imageCount: Int) -> ChatRouteConfiguration {
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
        stream: @escaping LLMRequest.ToolStream,
        routeResolver: (@MainActor (ChatModelSelection, Int, Bool) -> Result<ChatRouteConfiguration, ChatRouteBlocker>)? = nil,
        /// A synthetic ambient screen read. Nil leaves the live trail alone,
        /// which is nil while nothing records. Never starts a recording.
        ambientScreenRead: String? = nil
    ) -> LLMController {
        LLMController(
            request: LLMRequest(toolStream: stream),
            chatStore: store,
            storeIsInjected: true,
            sessionIDProvider: { nil },
            routeResolver: routeResolver ?? { _, imageCount, _ in .success(self.route(imageCount: imageCount)) },
            makeToolExecutor: nil,
            modeStore: .inMemory(),
            turnLogger: { _ in },
            ambientScreenProvider: Self.ambientProvider(ambientScreenRead)
        )
    }

    /// The injected ambient read as the controller's provider. Nil stays nil,
    /// so the live trail (idle while nothing records) is what is read.
    private static func ambientProvider(_ text: String?) -> (@MainActor () -> String?)? {
        guard let text else { return nil }
        return { text }
    }

    private func document(name: String = "report.pdf", text: String = "The number is 42.") -> ExternalDocumentAttachment {
        ExternalDocumentAttachment(
            name: name,
            text: text,
            path: "/tmp/\(name)",
            kind: .pdf,
            byteCount: text.utf8.count,
            pageCount: 1,
            wasCut: false,
            originalBytes: Data("%PDF-1.4 \(text)".utf8),
            normalizedImage: nil,
            document: ExtractedDocument.flat(
                kind: .pdf,
                kindLabel: "PDF",
                name: name,
                text: text
            )
        )
    }

    /// A dated log handed over from the Chats library: its recorded text is the
    /// source, and its prompt is left editable for the user.
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

    private func image(name: String, byte: UInt8) -> ExternalDocumentAttachment {
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

    // MARK: - Waiting

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        _ check: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func threadIDs() async throws -> [String] {
        try await store.summaries().map(\.id)
    }

    private func waitForTurns(_ expected: Int, in conversationID: String) async throws -> ConversationRecord {
        var latest: ConversationRecord?
        try await waitUntil("\(expected) stored turns in \(conversationID)") {
            let record = try await self.store.load(id: conversationID)
            latest = record
            return record.turns.count >= expected
        }
        return try XCTUnwrap(latest)
    }

    /// The first stored chat, once the send has committed it.
    private func waitForAThread() async throws -> String {
        var found: String?
        try await waitUntil("a stored chat") {
            found = try await self.store.summaries().first?.id
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// The exact body the provider was handed for one turn, as text. The store
    /// keeps it verbatim, so a test can assert what the wire carried.
    private func requestSnapshot(conversationID: String, turn: TurnRecord) async throws -> String {
        let hash = try XCTUnwrap(turn.request?.attachmentRefs.first?.snapshotHash)
        let refs = try await store.artifacts(kind: .requestSnapshot)
        let ref = try XCTUnwrap(refs.first { $0.sha256 == hash }, "the request snapshot is stored")
        return String(decoding: try await store.read(ref), as: UTF8.self)
    }

    /// How many image parts the stored request body carries. Counted from the
    /// decoded JSON, so it does not depend on key order or serialization.
    private static func imageParts(in value: Any) -> Int {
        switch value {
        case let object as [String: Any]:
            let own = object["image_url"] == nil ? 0 : 1
            return own + object.values.reduce(0) { $0 + imageParts(in: $1) }
        case let array as [Any]:
            return array.reduce(0) { $0 + imageParts(in: $1) }
        default:
            return 0
        }
    }

    private func assistantText(in controller: LLMController) -> String {
        controller.entries.last { $0.role == "assistant" }?.text ?? ""
    }

    // MARK: - 1. The new-chat boundary

    func testNewChatDropsTheRetainedSourcesAndSendsNoneOfThem() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(), image(name: "photo.png", byte: 0xAA)]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertEqual(controller.retainedImageCount, 1, "precondition: the chat retained its image")
        XCTAssertFalse(controller.retainedSourceNames.isEmpty)

        controller.newChat()
        XCTAssertEqual(controller.retainedImageCount, 0, "a new chat keeps no active source")
        XCTAssertTrue(controller.retainedSourceNames.isEmpty)
        XCTAssertTrue(controller.entries.isEmpty)

        // A bare question in the new chat must carry neither old bytes nor old
        // labels.
        controller.sendAskAnything("and what should we do next?")
        var secondID: String?
        try await waitUntil("the new chat's own thread") {
            secondID = try await self.threadIDs().first { $0 != id }
            return secondID != nil
        }
        let second = try XCTUnwrap(secondID)
        let record = try await waitForTurns(2, in: second)
        let userTurn = try XCTUnwrap(record.turns.first { $0.role == .user })
        let receipt = try XCTUnwrap(userTurn.request)
        XCTAssertEqual(receipt.context?.scope, RetrievalScope.none, "a source-less question is recorded as source-less")
        XCTAssertEqual(receipt.context?.sourceCharacters ?? 0, 0)
        XCTAssertEqual(receipt.extra["externalRetrieval"]?.boolValue, true)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 0)
        XCTAssertTrue(userTurn.attachments.isEmpty, "no attachment rides the new chat's first turn")

        let wire = try await requestSnapshot(conversationID: second, turn: userTurn)
        XCTAssertFalse(wire.contains("report.pdf"), "the old document is not on the wire")
        XCTAssertFalse(wire.contains("The number is 42."), "the old document's text is not on the wire")
        XCTAssertFalse(wire.contains("image_url"), "the old screenshot is not sent as an image")
        XCTAssertFalse(wire.contains("for this turn"), "a source-less turn claims no attached source")

        // The saved thread and its assets are untouched.
        let saved = try await store.load(id: id)
        XCTAssertEqual(saved.turns.count, 2)
        let retained = try await store.retainedAttachments(id: id)
        XCTAssertEqual(retained.map(\.name).sorted(), ["photo.png", "report.pdf"])
    }

    /// Starting a recording resets the in-memory chat context. It clears the
    /// active archive the same way `/new` does, and leaves the stored thread.
    func testASessionResetDropsTheActiveSourcesAndKeepsTheSavedThread() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document?",
            attachments: [document()]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertEqual(controller.retainedSourceNames, ["report.pdf"])

        // `SessionCoordinator.startSession` does exactly this.
        controller.resetMemory()
        XCTAssertTrue(controller.retainedSourceNames.isEmpty, "the recording start begins with no active source")
        XCTAssertTrue(controller.entries.isEmpty)

        controller.sendAskAnything("and what should we do next?")
        // The chat continues in the same thread; the turn carries no source.
        let record = try await waitForTurns(4, in: id)
        let userTurns = record.turns.filter { $0.role == .user }
        XCTAssertEqual(userTurns.count, 2)
        let receipt = try XCTUnwrap(userTurns[1].request)
        XCTAssertEqual(receipt.context?.scope, RetrievalScope.none)
        XCTAssertEqual(receipt.context?.sourceCharacters ?? 0, 0)
        XCTAssertTrue(userTurns[1].attachments.isEmpty)

        let wire = try await requestSnapshot(conversationID: id, turn: userTurns[1])
        XCTAssertFalse(wire.contains("The number is 42."), "the previous chat's document is not re-sent")
        let afterReset = try await threadIDs()
        XCTAssertEqual(afterReset, [id], "no second thread was created")
        let retained = try await store.retainedAttachments(id: id)
        XCTAssertEqual(retained.count, 1, "the saved thread keeps its own source")
    }

    /// Reattaching the same image and asking for a comparison: the wire keeps
    /// one copy (deduped by source id, fresh first), so the route, the receipt
    /// and the composer's own preview must all count one image, not two.
    func testReattachingTheSameImageInAComparisonIsCountedOnce() async throws {
        let routeImageCount = ValueBox()
        let controller = makeController(
            stream: textStream(),
            routeResolver: { _, imageCount, _ in
                routeImageCount.set(imageCount)
                return .success(self.route(imageCount: imageCount))
            }
        )

        controller.sendAskAnything("describe this image", attachments: [image(name: "same.png", byte: 0xAA)])
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertEqual(controller.retainedImageCount, 1)

        // The comparison question plus the same file again: these are the ids
        // the composer would pass for one fresh chip at /tmp/same.png.
        let samePath = "/tmp/same.png"
        XCTAssertEqual(
            controller.chosenImageCount(
                question: "compare with the earlier file",
                freshSourceIDs: [samePath],
                freshImageIDs: [samePath],
                screenImageCount: 0
            ),
            1,
            "a reattached source is previewed once, not once per copy"
        )

        routeImageCount.set(-1)
        controller.sendAskAnything(
            "compare with the earlier file",
            attachments: [image(name: "same.png", byte: 0xAA)]
        )
        let record = try await waitForTurns(4, in: id)
        XCTAssertEqual(routeImageCount.get(), 1, "the frozen route carries the deduped set")
        let secondUser = try XCTUnwrap(record.turns.filter { $0.role == .user }.last)
        let receipt = try XCTUnwrap(secondUser.request)
        XCTAssertEqual(receipt.context?.scope, .currentSourceAndHistory)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 1)
        XCTAssertEqual(secondUser.attachments.filter { $0.kind == .image }.count, 1)

        let wire = try await requestSnapshot(conversationID: id, turn: secondUser)
        let body = try JSONSerialization.jsonObject(with: Data(wire.utf8))
        XCTAssertEqual(
            Self.imageParts(in: body),
            1,
            "one image on the wire, so the preview's one matches it"
        )

        // A different second image is still counted: no undercounting.
        XCTAssertEqual(
            controller.chosenImageCount(
                question: "compare with the earlier file",
                freshSourceIDs: ["/tmp/other.png"],
                freshImageIDs: ["/tmp/other.png"],
                screenImageCount: 0
            ),
            2,
            "a new image beside the retained one is counted twice"
        )
    }

    // MARK: - 2. The same chat keeps its sources

    func testABareFollowUpInTheSameChatKeepsItsSources() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(), image(name: "photo.png", byte: 0xAA)]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)

        controller.sendAskAnything("and what else?")
        let record = try await waitForTurns(4, in: id)
        let userTurns = record.turns.filter { $0.role == .user }
        let receipt = try XCTUnwrap(userTurns[1].request)
        XCTAssertEqual(receipt.context?.scope, .currentSource, "the retained archive is the turn's source")
        XCTAssertGreaterThan(receipt.context?.sourceCharacters ?? 0, 0)
        XCTAssertEqual(receipt.extra["externalRetrieval"]?.boolValue, false)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 1, "the retained image is sent once")

        let wire = try await requestSnapshot(conversationID: id, turn: userTurns[1])
        XCTAssertTrue(wire.contains("The number is 42."), "the retained document answers the follow-up")
        XCTAssertTrue(wire.contains("earlier turns"), "the prompt names it as retained")
        XCTAssertFalse(wire.contains("for this turn"), "a retained source is not newly attached")
    }

    // MARK: - 3. Resuming a saved chat restores only its own sources

    func testResumingASavedChatRestoresOnlyItsOwnSources() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(name: "report-a.pdf", text: "Alpha is 42."), image(name: "a.png", byte: 0xAA)]
        )
        let first = try await waitForAThread()
        _ = try await waitForTurns(2, in: first)

        controller.newChat()
        controller.sendAskAnything(
            "what number is in this other document?",
            attachments: [document(name: "report-b.pdf", text: "Beta is 7.")]
        )
        try await waitUntil("the second thread is stored") {
            try await self.threadIDs().count == 2
        }
        let allIDs = try await threadIDs()
        let second = try XCTUnwrap(allIDs.first { $0 != first })
        _ = try await waitForTurns(2, in: second)
        XCTAssertEqual(controller.retainedSourceNames, ["report-b.pdf"])

        // Resume the first chat: only its own sources come back.
        await controller.resumeChat(id: first)
        XCTAssertTrue(controller.retainedSourceNames.contains("report-a.pdf"))
        XCTAssertFalse(controller.retainedSourceNames.contains("report-b.pdf"))
        XCTAssertEqual(controller.retainedImageCount, 1, "the first chat's own image is back")
        let afterResume = try await threadIDs()
        XCTAssertEqual(afterResume.count, 2, "resuming creates nothing")

        controller.sendAskAnything("and what else?")
        let record = try await waitForTurns(4, in: first)
        let userTurns = record.turns.filter { $0.role == .user }
        let receipt = try XCTUnwrap(userTurns[1].request)
        XCTAssertEqual(receipt.context?.scope, .currentSource)
        XCTAssertEqual(receipt.extra["imageCount"]?.doubleValue, 1)

        let wire = try await requestSnapshot(conversationID: first, turn: userTurns[1])
        XCTAssertTrue(wire.contains("Alpha is 42."))
        XCTAssertFalse(wire.contains("Beta is 7."), "another chat's source never rides this one")
        XCTAssertFalse(wire.contains("report-b.pdf"))
    }

    /// A tray file with no path is sent under its name. The preview must use
    /// that same shared id, so a pathless image is counted once, deduped
    /// against its own retained copy, and still counted when it is alone.
    func testAPathlessAttachmentKeepsItsImageCountAndDedupes() async throws {
        let pathless = ExternalDocumentAttachment(
            name: "clip.png",
            text: "An image.",
            path: nil,
            kind: .image,
            byteCount: 3,
            pageCount: nil,
            wasCut: false,
            originalBytes: Data([0xAA, 0xAA, 0xAA]),
            normalizedImage: DocumentImageBytes(
                data: Data([0xAA, 0xAA]),
                mimeType: "image/png",
                pixelWidth: 2,
                pixelHeight: 2
            ),
            document: ExtractedDocument.flat(kind: .image, kindLabel: "Image", name: "clip.png", text: "An image.")
        )
        XCTAssertEqual(pathless.wireSourceID, "Attached file: clip.png", "the one shared identity")

        let routeImageCount = ValueBox()
        let controller = makeController(
            stream: textStream(),
            routeResolver: { _, imageCount, _ in
                routeImageCount.set(imageCount)
                return .success(self.route(imageCount: imageCount))
            }
        )
        controller.sendAskAnything("describe this image", attachments: [pathless])
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertEqual(controller.retainedImageCount, 1)

        // A bare follow-up reads the retained copy: one image, not zero.
        XCTAssertEqual(
            controller.chosenImageCount(
                question: "and what else?",
                freshSourceIDs: [],
                freshImageIDs: [],
                screenImageCount: 0
            ),
            1
        )

        // The same pathless file again, in a comparison: sent once.
        routeImageCount.set(-1)
        XCTAssertEqual(
            controller.chosenImageCount(
                question: "compare with the earlier file",
                freshSourceIDs: [pathless.wireSourceID],
                freshImageIDs: [pathless.wireSourceID],
                screenImageCount: 0
            ),
            1,
            "the retained copy is deduped by the same id, pathless or not"
        )
        controller.sendAskAnything("compare with the earlier file", attachments: [pathless])
        let record = try await waitForTurns(4, in: id)
        XCTAssertEqual(routeImageCount.get(), 1)
        let secondUser = try XCTUnwrap(record.turns.filter { $0.role == .user }.last)
        XCTAssertEqual(try XCTUnwrap(secondUser.request).extra["imageCount"]?.doubleValue, 1)

        // The stored sources really have no path, so the id came from the shared
        // fallback and not from a path that happened to match. Each send records
        // its own copy; the chat's active archive still holds one source.
        let retainedPaths = try await store.retainedAttachments(id: id).map(\.path)
        XCTAssertFalse(retainedPaths.isEmpty)
        XCTAssertTrue(retainedPaths.allSatisfy { $0 == nil }, "\(retainedPaths)")
        XCTAssertEqual(controller.retainedImageCount, 1, "the archive deduped the reattached pathless image")
    }

    /// `resumeThread(id:)` adopts a stored thread without swapping the live
    /// entries, so it must not leave the previous chat's source archive active.
    /// The stored thread keeps its own sources; `resumeChat(id:)` is the path
    /// that restores them.
    func testAdoptingAThreadWithoutItsEntriesDropsTheActiveSources() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(), image(name: "photo.png", byte: 0xAA)]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertFalse(controller.retainedSourceNames.isEmpty, "precondition: a source is active")

        _ = try await controller.resumeThread(id: id)
        XCTAssertTrue(controller.retainedSourceNames.isEmpty, "no stale source survives the adoption")
        XCTAssertEqual(controller.retainedImageCount, 0)

        // The stored thread and its bytes are untouched.
        let retained = try await store.retainedAttachments(id: id)
        XCTAssertEqual(retained.map(\.name).sorted(), ["photo.png", "report.pdf"])
    }

    // MARK: - 4. Prompt, policy and receipt agree
    func testThePromptPolicyAndReceiptAgreeOnEverySourceSituation() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(), image(name: "photo.png", byte: 0xAA)]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        controller.sendAskAnything("and what else?")
        var record = try await waitForTurns(4, in: id)

        // A fresh-source turn and a retained follow-up: the sentence that
        // forbids a vault search appears exactly when the tools were withheld.
        for turn in record.turns.filter({ $0.role == .user }) {
            let receipt = try XCTUnwrap(turn.request)
            let wire = try await requestSnapshot(conversationID: id, turn: turn)
            let allowsExternal = try XCTUnwrap(receipt.extra["externalRetrieval"]?.boolValue)
            XCTAssertEqual(
                wire.contains("Do not search the vault"),
                !allowsExternal,
                "the prompt and the tool policy disagree on \(turn.text)"
            )
        }

        // A widened turn over the same chat: the source stays, the tools open.
        controller.broaderSearchEnabled = true
        controller.sendAskAnything("and what else should we consider?")
        record = try await waitForTurns(6, in: id)
        let widenedUser = try XCTUnwrap(record.turns.filter { $0.role == .user }.last)
        let widenedReceipt = try XCTUnwrap(widenedUser.request)
        XCTAssertEqual(widenedReceipt.extra["externalRetrieval"]?.boolValue, true)
        let widenedWire = try await requestSnapshot(conversationID: id, turn: widenedUser)
        XCTAssertFalse(widenedWire.contains("Do not search the vault"), "a widened turn may search")
        XCTAssertTrue(widenedWire.contains("The number is 42."), "and still carries its source")
    }

    // MARK: - 4b. The composer's own labels, from the controller's state

    /// The composer's "Next answer uses" line, from the controller that will
    /// send the turn: this chat's retained sources are named while they are on
    /// the wire, and the ambient screen read is named when (and only when) the
    /// same read goes into the request.
    func testThePreviewNamesRetainedSourcesAndTheAmbientReadThatIsSent() async throws {
        let ambient = "Ambient OCR: the shared document says the total is 42."
        let controller = makeController(stream: textStream(), ambientScreenRead: ambient)
        controller.sendAskAnything(
            "what number is in this document and image?",
            attachments: [document(), image(name: "photo.png", byte: 0xAA)]
        )
        let id = try await waitForAThread()
        let record = try await waitForTurns(2, in: id)
        let firstUser = try XCTUnwrap(record.turns.first)
        let wire = try await requestSnapshot(conversationID: id, turn: firstUser)
        XCTAssertTrue(
            wire.contains("the shared document says the total is 42"),
            "precondition: the ambient read is in the request"
        )

        // A bare follow-up sends the retained archive, so the footnote names it.
        let labels = controller.contextPreviewLabels(question: "", freshSourceIDs: [])
        XCTAssertTrue(labels.contains { $0.contains("This chat's saved sources") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("report.pdf") }, "the retained source is named, not counted")
        XCTAssertTrue(labels.contains(ContextDisclosureLabels.ambientScreenLabel), "the sent screen read is named")
        XCTAssertFalse(labels.contains("Live transcript"), "nothing invented")

        // With a fresh source attached, the retained archive is not on the
        // wire, so the footnote must not claim it is.
        let withFresh = controller.contextPreviewLabels(question: "", freshSourceIDs: ["fresh"])
        XCTAssertFalse(withFresh.contains { $0.contains("saved sources") }, "\(withFresh)")
        XCTAssertTrue(withFresh.contains(ContextDisclosureLabels.ambientScreenLabel))
    }

    /// A manual capture is named while it is waiting to send, and only then.
    func testThePreviewNamesTheManualCaptureOnlyWhileItIsPending() async throws {
        let controller = makeController(stream: textStream())
        XCTAssertFalse(controller.contextPreviewLabels(question: "", freshSourceIDs: []).contains(ContextDisclosureLabels.screenCaptureLabel))

        controller.attachScreenContext("Manual OCR: the agenda has four items.")
        XCTAssertTrue(controller.contextPreviewLabels(question: "", freshSourceIDs: []).contains(ContextDisclosureLabels.screenCaptureLabel))

        controller.clearPendingScreenContext()
        XCTAssertFalse(controller.contextPreviewLabels(question: "", freshSourceIDs: []).contains(ContextDisclosureLabels.screenCaptureLabel))
    }

    /// No screen read is claimed when none is configured, so the label never
    /// describes a screen block that is not sent. The live ambient trail needs
    /// a running recording, which these tests never start; the read is injected
    /// in the test above instead.
    func testThePreviewClaimsNoScreenReadWhenThereIsNone() async throws {
        let controller = makeController(stream: textStream())
        let labels = controller.contextPreviewLabels(question: "", freshSourceIDs: [])
        XCTAssertFalse(labels.contains(ContextDisclosureLabels.ambientScreenLabel))
        XCTAssertFalse(labels.contains(ContextDisclosureLabels.screenCaptureLabel))
    }

    /// After a reset the footnote drops the chat's saved sources with the
    /// archive, so it cannot name a source the next turn would not send.
    func testThePreviewForgetsRetainedSourcesAtTheNewChatBoundary() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything("what number is in this document?", attachments: [document()])
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertTrue(controller.contextPreviewLabels(question: "", freshSourceIDs: []).contains { $0.contains("This chat's saved sources") })

        controller.newChat()
        XCTAssertFalse(controller.contextPreviewLabels(question: "", freshSourceIDs: []).contains { $0.contains("saved sources") })
    }

    /// A dated hand-over stays pending across a resume, so the chat has BOTH a
    /// pending dated source and its retained archive. The next turn sends the
    /// dated source only, and the labels must say exactly that: the dated source
    /// is named and the retained archive is not.
    func testAPendingDatedSourceOverAResumedChatNamesOnlyWhatIsSent() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document?",
            attachments: [document(name: "report-a.pdf", text: "Alpha is 42.")]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)
        XCTAssertEqual(controller.retainedSourceNames, ["report-a.pdf"])

        // A dated hand-over starts a new chat and waits for Send; resuming a
        // stored chat does not consume or clear it.
        controller.applyDatedChatSeed(Self.datedSeed())
        await controller.resumeChat(id: id)
        XCTAssertNotNil(controller.pendingDatedSourceName, "precondition: the dated source survives the resume")
        XCTAssertEqual(controller.retainedSourceNames, ["report-a.pdf"])

        let question = "About this dated entry (12 Sep 2026 · 07:04): did it rain?"
        let labels = controller.contextPreviewLabels(question: question, freshSourceIDs: [])
        XCTAssertTrue(labels.contains { $0.contains("12 Sep 2026") }, "the dated source is named: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("saved sources") }, "the turn sends the dated source only: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("report-a.pdf") }, "\(labels)")

        // The send agrees: the dated source is the only fresh source, and the
        // retained document is not on the wire.
        controller.sendAskAnything(question)
        let record = try await waitForTurns(4, in: id)
        let userTurn = try XCTUnwrap(record.turns.filter { $0.role == .user }.last)
        let receipt = try XCTUnwrap(userTurn.request)
        XCTAssertEqual(receipt.context?.scope, .currentSource)
        XCTAssertGreaterThan(receipt.context?.sourceCharacters ?? 0, 0)
        let wire = try await requestSnapshot(conversationID: id, turn: userTurn)
        XCTAssertTrue(wire.contains("it rained"), "the dated source's text is on the wire")
        XCTAssertFalse(wire.contains("Alpha is 42."), "the retained document is not sent on a fresh-source turn")
    }

    /// The comparison question changes the source set, so the labels must change
    /// with it: a plain question with a fresh source sends only that source, and
    /// the same fresh source with "compare ... earlier" sends the retained
    /// archive too and names it. The old count-only preview said fresh-only for
    /// both.
    func testAnExplicitComparisonPreviewNamesTheRetainedSourcesItWillSend() async throws {
        let controller = makeController(stream: textStream())
        controller.sendAskAnything(
            "what number is in this document?",
            attachments: [document(name: "report-a.pdf", text: "Alpha is 42.")]
        )
        let id = try await waitForAThread()
        _ = try await waitForTurns(2, in: id)

        let fresh = document(name: "report-b.pdf", text: "Beta is 7.")
        let plain = controller.contextPreviewLabels(question: "what does this say?", freshSourceIDs: [fresh.wireSourceID])
        XCTAssertFalse(plain.contains { $0.contains("saved sources") }, "\(plain)")

        let comparison = controller.contextPreviewLabels(
            question: "compare this with the earlier file",
            freshSourceIDs: [fresh.wireSourceID]
        )
        XCTAssertTrue(
            comparison.contains { $0.contains("This chat's saved sources (report-a.pdf)") },
            "the retained source that will be sent is named: \(comparison)"
        )

        // The send agrees with the comparison preview.
        controller.sendAskAnything("compare this with the earlier file", attachments: [fresh])
        let record = try await waitForTurns(4, in: id)
        let userTurn = try XCTUnwrap(record.turns.filter { $0.role == .user }.last)
        let receipt = try XCTUnwrap(userTurn.request)
        XCTAssertEqual(receipt.context?.scope, .currentSourceAndHistory)
        XCTAssertEqual(receipt.context?.historyIncluded, true)
        let wire = try await requestSnapshot(conversationID: id, turn: userTurn)
        XCTAssertTrue(wire.contains("Beta is 7."))
        XCTAssertTrue(wire.contains("Alpha is 42."), "the retained source is on the wire, as the label said")
    }

    // MARK: - 5. Stop, failure and /new keep the partial answer

    /// A stream that emits one partial answer, then holds until it is
    /// cancelled. The partial is given time to land on the main actor, so the
    /// test drives the same ordering a real provider does.
    private func partialThenHoldStream(_ partial: String) -> LLMRequest.ToolStream {
        { _, _, _, _, onContent, _ in
            onContent(partial)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
    }

    private func waitForPartial(_ partial: String, in controller: LLMController) async throws {
        try await waitUntil("the partial answer to be on screen") {
            self.assistantText(in: controller) == partial
        }
    }

    private func waitForTerminalTurn(
        in conversationID: String,
        status: RequestStatus
    ) async throws -> TurnRecord {
        var terminal: TurnRecord?
        try await waitUntil("a \(status.rawValue) turn") {
            let record = try await self.store.load(id: conversationID)
            terminal = record.turns.last { $0.request?.status == status }
            return terminal != nil
        }
        return try XCTUnwrap(terminal)
    }

    func testStopKeepsThePartialAnswerInTheStoredThread() async throws {
        let partial = "Partial answer the user could read."
        let controller = makeController(stream: partialThenHoldStream(partial))
        controller.sendAskAnything("summarise this document", attachments: [document()])
        let id = try await waitForAThread()
        // The question is committed before the provider is called; the answer
        // row is written by the terminal write, not by this test.
        _ = try await waitForTurns(1, in: id)
        try await waitForPartial(partial, in: controller)

        controller.cancel()

        let cancelled = try await waitForTerminalTurn(in: id, status: .cancelled)
        XCTAssertEqual(cancelled.text, partial, "the stored answer is what the user read")
        XCTAssertEqual(cancelled.role, .assistant)

        // And the reloaded thread keeps it.
        let reloaded = try await store.load(id: id)
        XCTAssertEqual(reloaded.turns.last?.text, partial)
        XCTAssertEqual(reloaded.turns.last?.request?.status, .cancelled)
    }

    func testAProviderFailureKeepsThePartialAnswerInTheStoredThread() async throws {
        let partial = "Partial before the connection dropped."
        let stream: LLMRequest.ToolStream = { _, _, _, _, onContent, _ in
            onContent(partial)
            // Let the delta reach the main actor the way a real stream does.
            try? await Task.sleep(nanoseconds: 150_000_000)
            throw LLMError.streamError("connection dropped")
        }
        let controller = makeController(stream: stream)
        controller.sendAskAnything("summarise this document", attachments: [document()])
        let id = try await waitForAThread()
        // The question is committed before the provider is called; the answer
        // row is written by the terminal write, not by this test.
        _ = try await waitForTurns(1, in: id)
        try await waitForPartial(partial, in: controller)

        let failed = try await waitForTerminalTurn(in: id, status: .failed)
        XCTAssertEqual(failed.text, partial, "a failed turn keeps what it had said")
        XCTAssertNotNil(failed.error)
        let reloadedFailed = try await store.load(id: id)
        XCTAssertEqual(reloadedFailed.turns.last?.text, partial)
    }

    func testNewChatDuringAStreamKeepsThePartialAnswerInItsOwnThread() async throws {
        let partial = "Partial answer cut off by /new."
        let controller = makeController(stream: partialThenHoldStream(partial))
        controller.sendAskAnything("summarise this document", attachments: [document()])
        let id = try await waitForAThread()
        // The question is committed before the provider is called; the answer
        // row is written by the terminal write, not by this test.
        _ = try await waitForTurns(1, in: id)
        try await waitForPartial(partial, in: controller)

        controller.newChat()

        let cancelled = try await waitForTerminalTurn(in: id, status: .cancelled)
        XCTAssertEqual(cancelled.text, partial)
        let afterNewChat = try await threadIDs()
        XCTAssertEqual(afterNewChat, [id], "the answer stays filed in the chat it belonged to")
        XCTAssertTrue(controller.entries.isEmpty, "and the new chat starts empty")
    }

    /// The finished path is the same writer: the stored answer is the whole
    /// text, filed once.
    func testAFinishedAnswerIsStoredOnceWithItsFullText() async throws {
        let answer = "Head. Tail."
        let stream: LLMRequest.ToolStream = { _, _, _, _, onContent, _ in
            onContent("Head. ")
            onContent("Tail.")
            return LLMClient.StreamResult(toolCalls: [], finishReason: "stop", reasoningCharacters: 0)
        }
        let controller = makeController(stream: stream)
        controller.sendAskAnything("summarise this document", attachments: [document()])
        let id = try await waitForAThread()
        let completed = try await waitForTerminalTurn(in: id, status: .completed)
        XCTAssertEqual(completed.text, answer)
        let reloaded = try await store.load(id: id)
        XCTAssertEqual(reloaded.turns.count, 2, "one question, one answer")
    }
}

/// A tiny lock-protected value for a Sendable test closure.
private final class ValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ newValue: Int) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
