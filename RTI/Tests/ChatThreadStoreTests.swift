import HouseChatCore
import XCTest

/// RTI's durable chat store, against injected temporary roots. Nothing here
/// touches the live vault or the app's real Application Support folder.
final class ChatThreadStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() throws -> ChatThreadStore {
        try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true)
        ))
    }

    private let originalBytes = Data("%PDF-1.4 not a real pdf".utf8)

    private func submittedTurn(text: String, fileName: String = "report.pdf") -> ChatThreadStore.SubmittedTurn {
        ChatThreadStore.SubmittedTurn(
            text: text,
            model: ModelSelection(
                chosen: ModelChoice(provider: "deepseek", model: "deepseek-chat", thinking: "fast"),
                effective: ModelChoice(provider: "deepseek", model: "deepseek-chat", thinking: "fast")
            ),
            attachments: [
                ChatThreadStore.SubmittedAttachment(
                    kind: .pdf,
                    name: fileName,
                    path: "/tmp/\(fileName)",
                    byteCount: originalBytes.count,
                    pageCount: 12,
                    originalBytes: originalBytes,
                    originalExtension: "pdf",
                    extractedText: "The number is 42.",
                    wasCut: false
                )
            ]
        )
    }

    func testATurnCommitsItsRecordsAndItsBytesTogether() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: "Report", surface: .rtiCopilot, session: nil, appVersion: "test"
        )
        let commit = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))

        let saved = try XCTUnwrap(commit.conversation.turns.last)
        XCTAssertEqual(saved.text, "read this")
        XCTAssertEqual(saved.role, .user)
        XCTAssertEqual(saved.attachments.count, 1)

        let attachment = try XCTUnwrap(saved.attachments.first)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.name, "report.pdf")
        XCTAssertEqual(attachment.contentHash, SHA256Digest.hex(originalBytes))
        XCTAssertEqual(attachment.characterCount, "The number is 42.".count)
        XCTAssertNotNil(attachment.artifacts?.original, "the original bytes are referenced by the record")
        XCTAssertNotNil(attachment.artifacts?.extractedText)
        XCTAssertFalse(commit.createdDigests.isEmpty)
    }

    func testTheStoredBytesRoundTripAndVerify() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let commit = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        let ref = try XCTUnwrap(commit.createdArtifacts.first(where: { $0.kind == .original }))

        let bytes = try await store.read(ref)
        XCTAssertEqual(bytes, originalBytes)
        let verification = try await store.verify(ref)
        XCTAssertEqual(verification, .verified)
    }

    func testASecondTurnAppendsInsteadOfReplacingTheThread() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let first = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "first"))
        let second = try await store.appendTurn(
            to: first.conversation,
            turn: ChatThreadStore.SubmittedTurn(text: "second", role: .assistant)
        )

        XCTAssertEqual(second.conversation.turns.count, 2)
        XCTAssertEqual(second.conversation.turns.first?.text, "first")
        XCTAssertEqual(second.conversation.turns.last?.role, .assistant)
        XCTAssertEqual(second.turnIndex, 1)
    }

    func testTheThreadSurvivesAFreshStoreAndTheOriginalBeingDeleted() async throws {
        let conversationID = "chat-restart"
        do {
            let store = try store()
            let conversation = try await store.thread(
                id: conversationID, title: "Restart", surface: .rtiCopilot,
                session: nil, appVersion: nil
            )
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        }

        // A new store instance is what a relaunch looks like: the thread and
        // the bytes come back from disk, and the user's original file is gone.
        let reopened = try store()
        let resumed = try await reopened.thread(
            id: conversationID, title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        XCTAssertEqual(resumed.turns.count, 1, "the stored turn is resumed, not replaced")
        XCTAssertEqual(resumed.title, "Restart", "an existing thread keeps its own title")

        let ref = try XCTUnwrap(resumed.turns.first?.attachments.first?.artifacts?.original)
        let restored = try await reopened.read(ref)
        XCTAssertEqual(restored, originalBytes)
    }

    func testStorageUsageCountsTheStoredBytes() async throws {
        let store = try store()
        let empty = try await store.storageUsage()
        XCTAssertEqual(empty, 0)
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        let usage = try await store.storageUsage()
        XCTAssertGreaterThanOrEqual(usage, originalBytes.count)
    }

    func testBytesSurviveWhileAThreadRefersToThemAndGoWhenItIsDeleted() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let commit = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        let ref = try XCTUnwrap(commit.createdArtifacts.first(where: { $0.kind == .original }))

        let refused = try await store.removeArtifactsIfUnreferenced([ref])
        XCTAssertTrue(refused.isEmpty, "a referenced artifact is never removed")
        let stillThere = try await store.read(ref)
        XCTAssertEqual(stillThere, originalBytes)

        let owned = try await store.ownedArtifactRefs(id: "chat-1")
        let removed = try await store.delete(id: "chat-1")
        XCTAssertEqual(
            Set(removed.map(\.sha256)),
            Set(owned.map(\.sha256)),
            "delete removes exactly the bytes the thread owned"
        )
        XCTAssertTrue(removed.contains { $0.sha256 == ref.sha256 })
    }

    func testExportProducesTheStoredConversation() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: "Exportable", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))

        let exported = try await store.export(id: "chat-1")
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertTrue(text.contains("Exportable"))
        XCTAssertTrue(text.contains("read this"))
    }

    func testADamagedThreadIsReportedNotHiddenOrReplaced() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-good", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))

        // A file a newer build, or a bad write, left behind.
        let threads = root.appendingPathComponent("chats/threads", isDirectory: true)
        try Data("{ not json".utf8).write(to: threads.appendingPathComponent("broken.json"))

        let summaries = try await store.summaries()
        XCTAssertEqual(summaries.count, 2, "the good thread is not lost when a sibling is damaged")
        XCTAssertTrue(summaries.contains { $0.id == "chat-good" })
        XCTAssertTrue(summaries.contains { $0.issue != nil }, "the damaged file is reported, not hidden")
    }

    func testAReadOnlyAssetRootRefusesTheCommitAndSavesNothing() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let assets = root.appendingPathComponent("chat-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: assets.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assets.path) }

        do {
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
            XCTFail("a write into a read-only asset root must not succeed")
        } catch {
            // Expected: a write that cannot land must not save the turn.
            let summaries = try await store.summaries()
            XCTAssertEqual(summaries.count, 0, "a failed commit saves no conversation")
        }
    }

    // MARK: Corruption, pin, rename, and reference-aware deletion

    func testCorruptHistoryIsThrownNotReplaced() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-damaged", title: "Real history", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))

        // Damage the file the archive actually reads for this id.
        let threads = root.appendingPathComponent("chats/threads", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: threads, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        let damaged = try XCTUnwrap(files.first)
        try Data("{ not json at all".utf8).write(to: damaged)

        do {
            _ = try await store.thread(
                id: "chat-damaged", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
            )
            XCTFail("a damaged record must never be silently replaced with a fresh one")
        } catch {
            // Expected: the caller is told, so it can refuse to write.
        }

        let stillThere = try String(contentsOf: damaged, encoding: .utf8)
        XCTAssertTrue(stillThere.contains("not json at all"), "the damaged file is left exactly as it was")

        // And the damaged chat is reported, not hidden, by a listing.
        let summaries = try await store.summaries()
        XCTAssertTrue(summaries.contains { $0.id == "chat-damaged" && $0.issue != nil })
    }

    func testAMissingThreadStartsFresh() async throws {
        let store = try store()
        let fresh = try await store.thread(
            id: "chat-brand-new", title: "New", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        XCTAssertEqual(fresh.id, "chat-brand-new")
        XCTAssertTrue(fresh.turns.isEmpty)
    }

    func testRenameAndPinRoundTrip() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: "First", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))

        _ = try await store.rename(id: "chat-1", title: "Renamed")
        let renamed = try await store.load(id: "chat-1")
        XCTAssertEqual(renamed.title, "Renamed")

        let unpinned = try await store.isPinned(id: "chat-1")
        XCTAssertFalse(unpinned)
        _ = try await store.setPinned(id: "chat-1", true)
        let pinned = try await store.isPinned(id: "chat-1")
        XCTAssertTrue(pinned)
        let namespaced = try await store.load(id: "chat-1")
        XCTAssertEqual(namespaced.appPayload?.namespace, "rti")

        _ = try await store.setPinned(id: "chat-1", false)
        let unpinnedAgain = try await store.isPinned(id: "chat-1")
        XCTAssertFalse(unpinnedAgain)
    }

    func testDeleteKeepsBytesAnotherThreadStillUses() async throws {
        let store = try store()
        for id in ["chat-a", "chat-b"] {
            let conversation = try await store.thread(
                id: id, title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
            )
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        }

        let removed = try await store.delete(id: "chat-a")
        XCTAssertTrue(removed.isEmpty, "the other thread still points at the same bytes")

        let refs = try await store.ownedArtifactRefs(id: "chat-b")
        let ref = try XCTUnwrap(refs.first)
        let bytes = try await store.read(ref)
        XCTAssertEqual(bytes, originalBytes)
    }

    func testRequestSnapshotIsStoredAndReferencedByTheReceipt() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let snapshot = Data(#"{"model":"deepseek-chat","messages":[]}"#.utf8)
        let commit = try await store.appendTurn(
            to: conversation,
            turn: ChatThreadStore.SubmittedTurn(
                text: "read this",
                request: RequestReceipt(selection: ModelSelection(ModelChoice(provider: "deepseek")), status: .completed),
                requestSnapshot: snapshot
            )
        )

        let turn = try XCTUnwrap(commit.conversation.turns.last)
        let ref = try XCTUnwrap(turn.request?.attachmentRefs.first?.snapshotHash)
        XCTAssertEqual(ref, SHA256Digest.hex(snapshot))

        let owned = try await store.ownedArtifactRefs(id: "chat-1")
        XCTAssertTrue(owned.contains { $0.sha256 == ref }, "the snapshot is owned through the receipt")
    }

    func testAFailedAndACancelledAnswerAreStoredWithTheirStatus() async throws {
        let store = try store()
        var conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let question = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        conversation = question.conversation

        let failed = try await store.appendTurn(
            to: conversation,
            turn: ChatThreadStore.SubmittedTurn(
                text: "",
                role: .assistant,
                request: RequestReceipt(status: .failed, error: "HTTP 500"),
                timings: TurnTimings(totalSeconds: 1.5),
                error: "HTTP 500"
            )
        )
        let cancelled = try await store.appendTurn(
            to: failed.conversation,
            turn: ChatThreadStore.SubmittedTurn(
                text: "",
                role: .assistant,
                request: RequestReceipt(status: .cancelled),
                timings: TurnTimings(totalSeconds: 2.5)
            )
        )

        XCTAssertEqual(cancelled.conversation.turns.count, 3)
        XCTAssertEqual(cancelled.conversation.turns[1].request?.status, .failed)
        XCTAssertEqual(cancelled.conversation.turns[1].error, "HTTP 500")
        XCTAssertEqual(cancelled.conversation.turns[2].request?.status, .cancelled)
    }

    // MARK: Metadata racing a streaming answer

    func testARenameLandingBeforeAnAppendIsNotClobbered() async throws {
        let store = try store()
        // The caller holds a stale copy: this is what the controller has in
        // memory while an answer streams.
        let created = try await store.thread(
            id: "chat-1", title: "Original", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let first = try await store.appendTurn(to: created, turn: submittedTurn(text: "first"))
        // The caller holds a stale copy: this is what the controller has in
        // memory while the next answer streams.
        let stale = first.conversation
        _ = try await store.rename(id: "chat-1", title: "Renamed while answering")

        let commit = try await store.appendTurn(to: stale, turn: submittedTurn(text: "read this"))
        XCTAssertEqual(commit.conversation.title, "Renamed while answering",
                       "a whole-record save must not undo a rename that already landed")
        let reread = try await store.load(id: "chat-1")
        XCTAssertEqual(reread.title, "Renamed while answering")
    }

    func testAPinLandingBeforeAnAppendIsNotClobbered() async throws {
        let store = try store()
        let created = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let first = try await store.appendTurn(to: created, turn: submittedTurn(text: "first"))
        let stale = first.conversation
        _ = try await store.setPinned(id: "chat-1", true)

        let commit = try await store.appendTurn(to: stale, turn: submittedTurn(text: "read this"))
        XCTAssertEqual(commit.conversation.appPayload?[ChatThreadStore.pinnedPayloadKey]?.boolValue, true)
        let pinned = try await store.isPinned(id: "chat-1")
        XCTAssertTrue(pinned)
    }

    func testARenameRacingAnAppendWinsEitherWay() async throws {
        let store = try store()
        let created = try await store.thread(
            id: "chat-1", title: "Original", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let firstTurn = submittedTurn(text: "first")
        let conversation = try await store.appendTurn(to: created, turn: firstTurn).conversation
        // Built before the racing tasks so neither captures the test case.
        let racing = submittedTurn(text: "read this")
        async let appended = store.appendTurn(to: conversation, turn: racing)
        async let renamed = store.rename(id: "chat-1", title: "Renamed mid-flight")
        _ = try await appended
        _ = try await renamed

        let final = try await store.load(id: "chat-1")
        XCTAssertEqual(final.title, "Renamed mid-flight")
        XCTAssertEqual(final.turns.count, 2, "the answer is stored too")
    }

    func testDeletingTheActiveChatBlocksFurtherAppendsUntilANewChat() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "first"))
        _ = try await store.delete(id: "chat-1")

        do {
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "late answer"))
            XCTFail("an answer that was streaming when the chat was deleted must not recreate it")
        } catch {
            // Expected: refused, not silently recreated.
        }
        let summaries = try await store.summaries()
        XCTAssertTrue(summaries.isEmpty, "the deleted chat stays deleted")

        // An explicit new chat on the same id is allowed.
        let fresh = try await store.thread(
            id: "chat-1", title: "New chat", surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let commit = try await store.appendTurn(to: fresh, turn: submittedTurn(text: "new chat"))
        XCTAssertEqual(commit.conversation.turns.count, 1)
        XCTAssertEqual(commit.conversation.title, "New chat")
    }

    // MARK: Checkpoints, interruption, retained sources

    private func extractedDocument(text: String = "The number is 42.") -> ExtractedDocument {
        ExtractedDocument(
            kind: .pdf,
            kindLabel: "PDF",
            name: "report.pdf",
            sections: [DocumentSection(label: "Page 1", unit: .page, index: 1, text: text)],
            sectionUnit: .page,
            unitCount: 1,
            characterCount: text.count,
            text: text
        )
    }

    private func turnWithDocument(text: String = "read this") -> ChatThreadStore.SubmittedTurn {
        var turn = submittedTurn(text: text)
        turn.attachments = [
            ChatThreadStore.SubmittedAttachment(
                kind: .pdf,
                name: "report.pdf",
                path: "/tmp/report.pdf",
                byteCount: originalBytes.count,
                pageCount: 1,
                originalBytes: originalBytes,
                originalExtension: "pdf",
                extractedText: "The number is 42.",
                extractedDocument: extractedDocument()
            )
        ]
        return turn
    }

    func testACheckpointAndItsFinishedFormAreOneTurn() async throws {
        let store = try store()
        var conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        conversation = try await store.appendTurn(to: conversation, turn: turnWithDocument()).conversation

        let turnID = UUID().uuidString
        try await store.checkpoint(
            conversationID: "chat-1",
            turnID: turnID,
            text: "The number",
            startedAt: Date(),
            model: ModelSelection(ModelChoice(provider: "deepseek"))
        )
        var checkpointed = try await store.load(id: "chat-1")
        XCTAssertEqual(checkpointed.turns.count, 2, "the checkpoint makes one turn")
        XCTAssertEqual(checkpointed.turns.last?.request?.status, .streaming)
        XCTAssertEqual(checkpointed.turns.last?.text, "The number")

        // The terminal write replaces that same turn.
        _ = try await store.appendTurn(
            to: checkpointed,
            turn: ChatThreadStore.SubmittedTurn(
                id: turnID,
                text: "The number is 42.",
                role: .assistant,
                request: RequestReceipt(status: .completed),
                timings: TurnTimings(totalSeconds: 2)
            )
        )
        let finished = try await store.load(id: "chat-1")
        XCTAssertEqual(finished.turns.count, 2, "a checkpointed answer is still one turn")
        XCTAssertEqual(finished.turns.last?.text, "The number is 42.")
        XCTAssertEqual(finished.turns.last?.request?.status, .completed)
    }

    func testAProcessDeathLeavesAnInterruptedTurn() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "read this"))
        let turnID = UUID().uuidString
        try await store.checkpoint(
            conversationID: "chat-1",
            turnID: turnID,
            text: "half an ans",
            startedAt: Date(),
            model: nil
        )

        // What a relaunch does.
        let marked = try await store.markInterrupted(id: "chat-1")
        XCTAssertEqual(marked, 1)
        let recovered = try await store.load(id: "chat-1")
        XCTAssertEqual(recovered.turns.last?.request?.status, .cancelled)
        XCTAssertEqual(recovered.turns.last?.text, "half an ans", "the partial words are kept")
        XCTAssertTrue(recovered.turns.last?.error?.contains("Interrupted") == true)

        // Idempotent: a second resume marks nothing.
        let again = try await store.markInterrupted(id: "chat-1")
        XCTAssertEqual(again, 0)
    }

    func testRetainedSourcesComeFromTheStoreNotTheDisk() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-1", title: nil, surface: .rtiCopilot, session: nil, appVersion: nil
        )
        let commit = try await store.appendTurn(to: conversation, turn: turnWithDocument())
        let ref = try XCTUnwrap(commit.createdArtifacts.first { $0.kind == .original })

        // The recorded path is not a real file at all: nothing may be re-read
        // from disk, so the store's own bytes are the only source.

        let retained = try await store.retainedAttachments(id: "chat-1")
        let only = try XCTUnwrap(retained.first)
        XCTAssertEqual(only.originalBytes, originalBytes)
        XCTAssertEqual(only.document?.sections.count, 1)
        XCTAssertEqual(only.extractedText, "The number is 42.")
        XCTAssertFalse(only.isMissing)

        // Now the store's copy goes too: the reader says so, and never refetches.
        let artifactFile = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root.appendingPathComponent("chat-assets", isDirectory: true),
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }.first { $0.lastPathComponent == ref.sha256 }
        )
        try FileManager.default.removeItem(at: artifactFile)

        let afterLoss = try await store.retainedAttachments(id: "chat-1")
        let lost = try XCTUnwrap(afterLoss.first)
        XCTAssertTrue(lost.isMissing, "a record pointing at lost bytes says so")
        XCTAssertNil(lost.originalBytes)
        XCTAssertNotNil(lost.document, "the extracted record is a separate artifact and still reads")
    }

    // MARK: Session projection

    private func linkedThread(
        id: String,
        session: String?,
        turnText: String
    ) async throws -> ChatThreadStore {
        let store = try store()
        let conversation = try await store.thread(
            id: id,
            title: "Chat \(id)",
            surface: session == nil ? .rtiCopilot : .rtiMeeting,
            session: session.map { SessionLink(kind: "rti-session", id: $0, label: "RTI session") },
            appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: turnText))
        return store
    }

    func testARecordingProjectsEveryChatItHeldWithExactIds() async throws {
        let store = try store()
        for (id, session, text) in [
            ("chat-a", "session-1", "first chat in the recording"),
            ("chat-b", "session-1", "second chat, after /new"),
            ("chat-c", "session-2", "a different recording"),
            ("chat-d", nil, "a standalone chat"),
        ] {
            let conversation = try await store.thread(
                id: id,
                title: "Chat \(id)",
                surface: session == nil ? .rtiCopilot : .rtiMeeting,
                session: session.map { SessionLink(kind: "rti-session", id: $0, label: "RTI session") },
                appVersion: nil
            )
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: text))
        }

        let projection = await store.sessionChatProjection(linkedToSession: "session-1")
        XCTAssertEqual(projection.threads.map(\.id), ["chat-a", "chat-b"],
                       "the recording's two chats, in creation order, and nothing guessed by time")
        XCTAssertEqual(projection.unreadable, 0)

        let stored = try await store.load(id: "chat-a")
        let expectedTurnIDs = stored.turns.map(\.id)
        XCTAssertEqual(projection.threads[0].turns.map(\.id), expectedTurnIDs,
                       "every turn keeps the id it has in the record")
        XCTAssertEqual(projection.threads[0].turns.map(\.role), ["user"])
        XCTAssertEqual(projection.threads[1].turns[0].text, "second chat, after /new")
    }

    func testDeletingOneLinkedChatLeavesTheOthersProjected() async throws {
        let store = try store()
        for id in ["chat-a", "chat-b"] {
            let conversation = try await store.thread(
                id: id,
                title: nil,
                surface: .rtiMeeting,
                session: SessionLink(kind: "rti-session", id: "session-1", label: "RTI session"),
                appVersion: nil
            )
            _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "in \(id)"))
        }

        // Only the exact id goes.
        _ = try await store.delete(id: "chat-a")

        let projection = await store.sessionChatProjection(linkedToSession: "session-1")
        XCTAssertEqual(projection.threads.map(\.id), ["chat-b"])
        let remaining = try await store.load(id: "chat-b")
        XCTAssertEqual(remaining.turns.count, 1, "the other chat is untouched")
        XCTAssertFalse(store.contains(id: "chat-a"))
    }

    func testAnUnreadableSiblingIsCountedNotHidden() async throws {
        let store = try store()
        let conversation = try await store.thread(
            id: "chat-a",
            title: nil,
            surface: .rtiMeeting,
            session: SessionLink(kind: "rti-session", id: "session-1", label: "RTI session"),
            appVersion: nil
        )
        _ = try await store.appendTurn(to: conversation, turn: submittedTurn(text: "kept"))

        let threads = root.appendingPathComponent("chats/threads", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: threads, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        try Data("{ not json".utf8).write(to: try XCTUnwrap(files.first))

        let projection = await store.sessionChatProjection(linkedToSession: "session-1")
        XCTAssertEqual(projection.unreadable, 1, "a damaged sibling is counted, never silently dropped")
    }
}
