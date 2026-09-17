import HouseChatCore
import XCTest

/// The Chats library's own behaviour: what it loads, what it changes through
/// the store, what it refuses to lose, and what it says when there is no
/// store at all.
///
/// The roots are temporary, so nothing here touches the live vault, the real
/// Application Support folder, or a stored chat. No view is rendered: the
/// render proofs own that.
/// Points RTI's single path authority at a temporary config home for the
/// length of one test.
///
/// The store's own deletion resolves the vault itself (`VaultLogStore`), so
/// without this a test could read, or rewrite, a live daily log. With it,
/// every path RTI resolves lands inside the test's own temporary root.
private struct TempConfigHome {
    private let previous: String?
    private let path: String

    init(under root: URL) throws {
        previous = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        let home = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // `recordings_dir` anchors the tree: databases is two levels up.
        let recordings = root.appendingPathComponent("kb/databases/meetings/recordings", isDirectory: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["recordings_dir": recordings.path],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: home.appendingPathComponent("config.json"))
        path = home.path
        setenv("RTI_CONFIG_HOME", path, 1)
    }

    func restore() {
        if let previous {
            setenv("RTI_CONFIG_HOME", previous, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
    }
}

@MainActor
final class ChatLibraryModelTests: XCTestCase {
    private var root: URL!
    private var location: ChatLibraryLocation!
    private var original: URL!
    private var configHome: TempConfigHome?

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The store's deletion resolves the vault itself; keep it in here.
        configHome = try TempConfigHome(under: root)

        let store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true)
        ))
        location = ChatLibraryLocation(
            store: store,
            legacyTurnsRoot: root.appendingPathComponent("turns", isDirectory: true)
        )

        // The user's own document, which a chat may point at and never owns.
        original = root.appendingPathComponent("northwind-pricing.pdf")
        let bytes = Data("%PDF-1.4 the user's own document".utf8)
        try bytes.write(to: original)

        let pinned = try await store.thread(
            id: "chat-pinned", title: "Northwind pricing teardown", surface: .rtiCopilot, session: nil, appVersion: "test"
        )
        let committed = try await store.appendTurn(to: pinned, turn: ChatThreadStore.SubmittedTurn(
            text: "What does the pricing page do wrong?",
            attachments: [ChatThreadStore.SubmittedAttachment(
                kind: .pdf,
                name: "northwind-pricing.pdf",
                path: original.path,
                byteCount: bytes.count,
                pageCount: 12,
                originalBytes: bytes,
                originalExtension: "pdf",
                extractedText: "The plan table is doing too much."
            )]
        ))
        _ = try await store.appendTurn(to: committed.conversation, turn: ChatThreadStore.SubmittedTurn(
            text: "Three tiers, one highlighted, and the FAQ moves under the table.",
            role: .assistant
        ))
        _ = try await store.setPinned(id: "chat-pinned", true)

        let plain = try await store.thread(id: "chat-plain", title: nil, surface: .rtiCopilot, session: nil, appVersion: "test")
        _ = try await store.appendTurn(to: plain, turn: ChatThreadStore.SubmittedTurn(
            text: "Summarise the onboarding scope for Northwind before Thursday."
        ))
    }

    override func tearDown() async throws {
        configHome?.restore()
        configHome = nil
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func library() async -> ChatLibraryModel {
        let library = ChatLibraryModel(location: location)
        await library.loadIfNeeded()
        return library
    }

    /// One truly legacy day: no row names a saved chat. A newer row does name
    /// one, and is written by `addLinkedProjectionDay()`.
    private func writeLegacyDay() throws {
        try writeLegacyDay("2026-09-12", lines: [legacyLine], extra: [])
    }

    /// A day whose readable rows all belong to saved chats.
    private func addLinkedProjectionDay() throws {
        try writeLegacyDay("2026-09-11", lines: [], extra: [
            #"{"ts":"2026-09-11T07:04:00Z","action":"Ask","userInput":"a chat's own turn","output":"already listed as a chat","threadID":"chat-pinned"}"#,
        ])
    }

    private var legacyLine: String {
        #"{"ts":"2026-09-12T07:04:00Z","action":"Assist","inSession":true,"userInput":"What is their objection to the price?","output":"They compared it to the incumbent's entry tier.","transcriptContext":"a transcript the library must not keep"}"#
    }

    private func writeLegacyDay(_ day: String, lines: [String], extra: [String]) throws {
        let turns = root.appendingPathComponent("turns", isDirectory: true)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let body = (lines + extra + [""]).joined(separator: "\n")
        try body.write(
            to: turns.appendingPathComponent("\(day).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Loading

    func testItLoadsTheSavedChatsThePinnedStateAndTheSourceList() async throws {
        try writeLegacyDay()
        let library = await library()

        XCTAssertEqual(library.rows.count, 2)
        XCTAssertEqual(library.sections.map(\.title), ["Pinned", "Recent"], "the pinned chat gets its own group")
        XCTAssertEqual(library.sections.first?.rows.map(\.id), ["chat-pinned"])
        XCTAssertTrue(library.rows.contains { $0.id == "chat-pinned" && $0.isPinned })
        XCTAssertEqual(
            library.rows.first { $0.id == "chat-plain" }?.title.hasPrefix("Summarise the onboarding scope for Northwind"),
            true,
            "a chat with no name shows its first question"
        )
        XCTAssertEqual(library.legacyLogs.count, 1)
        XCTAssertNotNil(library.storageLine)
        XCTAssertTrue(library.storageLine?.contains("2 saved chats") == true)
        XCTAssertTrue(library.storageLine?.contains("1 dated log") == true)
        XCTAssertNil(library.errorText)

        library.select(id: "chat-pinned")
        await library.loadDetail()
        let detail = try XCTUnwrap(library.detail)
        XCTAssertEqual(detail.turns.count, 2)
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertEqual(detail.sources.first?.state, .verified, "the archived copy is checked by hash, not by the record's path")
        XCTAssertEqual(detail.sources.first?.sourcePath, original.path)
    }

    func testSearchKeepsThePinnedChatAheadAndFindsItByItsTurnText() async throws {
        let library = await library()
        library.query = "tiers"
        let sections = library.sections
        XCTAssertEqual(sections.map(\.title), ["Results"])
        XCTAssertEqual(sections.first?.rows.map(\.id), ["chat-pinned"], "an answer's text is searchable")
        XCTAssertEqual(library.headerTitle, "Chats")
    }

    func testRenamingAndPinningGoThroughTheStoreAndComeBack() async throws {
        let library = await library()
        library.beginRename(id: "chat-plain")
        XCTAssertEqual(library.renameText, "", "a chat named from its question starts with an empty field")
        library.renameText = "  Onboarding scope  "
        await library.commitRename()

        XCTAssertEqual(library.rows.first { $0.id == "chat-plain" }?.title, "Onboarding scope")
        XCTAssertEqual(library.notice, "Chat renamed.")

        await library.togglePin(id: "chat-plain")
        XCTAssertTrue(library.rows.first { $0.id == "chat-plain" }?.isPinned == true)
        XCTAssertEqual(
            library.sections.first?.rows.map(\.id),
            ["chat-plain", "chat-pinned"],
            "a newly pinned chat joins the pinned group, newest first"
        )

        await library.togglePin(id: "chat-plain")
        XCTAssertFalse(library.rows.first { $0.id == "chat-plain" }?.isPinned == true)

        // A cleared name falls back to the first question rather than keeping
        // a name nobody wrote.
        library.beginRename(id: "chat-plain")
        library.renameText = "   "
        await library.commitRename()
        XCTAssertEqual(
            library.rows.first { $0.id == "chat-plain" }?.title.hasPrefix("Summarise the onboarding scope for Northwind"),
            true,
            "the row falls back to the first question"
        )
        XCTAssertEqual(library.notice, "Name cleared. The row shows the first question again.")
    }

    // MARK: - Deletion

    func testDeletionWaitsForConfirmationAndKeepsTheUsersOwnFile() async throws {
        let library = await library()
        library.select(id: "chat-pinned")
        await library.loadDetail()
        let owned = try XCTUnwrap(library.detail?.sources.first?.contentHash)

        library.requestDeletion(id: "chat-pinned")
        XCTAssertTrue(library.isDeleteConfirmationPresented)
        XCTAssertTrue(library.rows.contains { $0.id == "chat-pinned" }, "asking removes nothing")

        library.confirmDeletion()
        await library.deleteConfirmed()

        XCTAssertFalse(library.rows.contains { $0.id == "chat-pinned" })
        XCTAssertNil(library.openID, "the deleted chat is no longer open")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the user's own file is kept")
        XCTAssertEqual(try Data(contentsOf: original), Data("%PDF-1.4 the user's own document".utf8))
        let notice = try XCTUnwrap(library.notice)
        XCTAssertTrue(notice.contains("Linked meetings, recordings, and your own files are untouched."))

        // The chat's own archived copy went with it.
        let left = try await location.store.artifacts()
        XCTAssertFalse(left.contains { $0.sha256 == owned && $0.kind == .original })
        XCTAssertEqual(library.rows.count, 1)
    }

    func testCancellingTheDeletionKeepsTheChat() async throws {
        let library = await library()
        library.requestDeletion(id: "chat-plain")
        library.cancelDeletion()
        XCTAssertFalse(library.isDeleteConfirmationPresented)
        XCTAssertNil(library.deletionRequest)
        XCTAssertTrue(library.rows.contains { $0.id == "chat-plain" })
    }

    // MARK: - Refusals and states

    func testAChatWhoseFileIsGoneSaysSoInsteadOfShowingNothing() async throws {
        let library = await library()
        library.select(id: "chat-that-never-existed")
        await library.loadDetail()
        XCTAssertTrue(library.detail?.turns.isEmpty == true)
        XCTAssertNotNil(library.detailNoticeText)
        XCTAssertTrue(library.detailNoticeText?.contains("not there any more") == true)
    }

    func testAnUnreadableStoreKeepsWhatWasAlreadyShownAndSaysWhy() async throws {
        let library = await library()
        XCTAssertEqual(library.rows.count, 2)

        // A store rooted at a file, not a directory: the list cannot read it.
        let broken = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: broken)
        let store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: broken
        ))
        let second = ChatLibraryModel(location: ChatLibraryLocation(
            store: store,
            legacyTurnsRoot: root.appendingPathComponent("turns", isDirectory: true)
        ))
        await second.loadIfNeeded()
        XCTAssertNotNil(second.errorText, "an unreadable store is not an empty one")
        XCTAssertTrue(second.rows.isEmpty)
    }

    func testWithNoStoreAtAllTheLibrarySaysItIsUnavailable() async throws {
        let library = ChatLibraryModel(location: nil)
        await library.loadIfNeeded()
        XCTAssertTrue(library.isUnavailable)
        XCTAssertTrue(library.rows.isEmpty)
        XCTAssertTrue(library.legacyLogs.isEmpty)
        XCTAssertNil(library.storageLine)
        XCTAssertEqual(library.headerTitle, "Chats")
        XCTAssertEqual(library.headerLine, "0 saved chats")
        XCTAssertNil(library.errorText)
    }

    func testADatedLogOpensAsANewChatRatherThanGuessingBoundaries() async throws {
        try writeLegacyDay()
        let library = await library()
        XCTAssertEqual(library.legacyLogs.count, 1)

        library.select(logID: "2026-09-12")
        XCTAssertEqual(library.headerTitle, "12 Sep 2026")
        XCTAssertTrue(library.headerLine.hasPrefix("Dated log · 1 turn"))
        await library.loadDetail()
        XCTAssertNil(library.detail, "a dated log is not a chat, so no chat is loaded")

        // Reusing the day never rewrites the log into a conversation, and
        // never saves anything: the entries go across as dated source.
        library.openDatedLogAsNewChat()
        XCTAssertTrue(library.rows.allSatisfy { $0.id != "2026-09-12" }, "no chat was invented for the day")
        XCTAssertTrue(library.headerLine.hasPrefix("Dated log · 1 turn"))
        let notice = try XCTUnwrap(library.notice)
        XCTAssertTrue(notice.contains("Nothing is sent until you send it."))
    }

    func testSearchingAlsoFindsADatedLogByItsTurnsText() async throws {
        try writeLegacyDay()
        let library = await library()
        library.query = "incumbent"
        XCTAssertEqual(library.legacyMatches.map(\.id), ["2026-09-12"])
        library.query = "nothing here"
        XCTAssertTrue(library.legacyMatches.isEmpty)
    }

    // MARK: - The boundary to the live chat

    /// What the assistant listens for: `rtiResumeChat` with the chat's id as a
    /// string. The library never reaches into the composer itself.
    func testResumingPostsTheChatIDOnTheNotificationTheAppListensFor() async throws {
        let library = await library()
        let notices = NoticeBox()
        let token = NotificationCenter.default.addObserver(forName: .rtiResumeChat, object: nil, queue: nil) { note in
            notices.record(name: note.name, object: note.object)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        library.resume(id: "chat-plain")

        XCTAssertEqual(notices.peek()?.name, "rtiResumeChat")
        XCTAssertEqual(notices.peek()?.object as? String, "chat-plain")
        XCTAssertEqual(library.openID, "chat-plain", "and the library shows the chat it resumed")
        XCTAssertNotNil(library.notice)
    }

    /// Reuse is a real payload: the seed the handler needs, with the recorded
    /// entries in it. It is not a bare clear, and it names no chat.
    func testUsingADatedLogInANewChatPostsTheTypedSeedAndSendsNothing() async throws {
        try writeLegacyDay()
        let library = await library()
        library.select(logID: "2026-09-12")

        let notices = NoticeBox()
        let token = NotificationCenter.default.addObserver(
            forName: ChatLibraryDatedSeed.notificationName,
            object: nil,
            queue: nil
        ) { note in
            notices.record(name: note.name, object: note.object)
        }
        let clearToken = NotificationCenter.default.addObserver(forName: .rtiClearChat, object: nil, queue: nil) { note in
            notices.record(name: note.name, object: note.object)
        }
        let resumeToken = NotificationCenter.default.addObserver(forName: .rtiResumeChat, object: nil, queue: nil) { note in
            notices.record(name: note.name, object: note.object)
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            NotificationCenter.default.removeObserver(clearToken)
            NotificationCenter.default.removeObserver(resumeToken)
        }

        library.openDatedLogAsNewChat()

        XCTAssertEqual(notices.count, 1, "one notification, and it is the seed")
        XCTAssertEqual(ChatLibraryDatedSeed.notificationName.rawValue, "rtiSeedDatedChat")
        let seed = try XCTUnwrap(notices.peek()?.object as? ChatLibraryDatedSeed)
        XCTAssertEqual(seed.scope, .day)
        XCTAssertEqual(seed.day, "2026-09-12")
        XCTAssertEqual(seed.entries.map(\.question), ["What is their objection to the price?"])
        XCTAssertTrue(seed.sourceText.contains("**Asked:** What is their objection to the price?"))
        XCTAssertTrue(seed.sourceText.contains("**Answered:** They compared it to the incumbent's entry tier."))
        XCTAssertFalse(seed.sourceText.contains("a transcript the library must not keep"))
        XCTAssertFalse(seed.prompt.isEmpty, "an editable draft, not an autosend")
        XCTAssertTrue(seed.prompt.hasSuffix(": "), "the draft invites the user, it does not ask for them")
        XCTAssertNotNil(seed.sourcePath, "the log file as metadata")

        let notice = try XCTUnwrap(library.notice)
        XCTAssertTrue(notice.contains("Nothing is sent until you send it."))
    }

    /// One recorded turn is enough scope: a per-entry action seeds only it.
    func testUsingOneDatedEntryPostsOnlyThatEntry() async throws {
        try writeLegacyDay("2026-09-12", lines: [
            legacyLine,
            #"{"ts":"2026-09-12T08:00:00Z","action":"Recap","userInput":"Recap so far","output":"Pricing framing and tier naming."}"#,
        ], extra: [])
        let library = await library()
        library.select(logID: "2026-09-12")
        let log = try XCTUnwrap(library.openLog)
        XCTAssertEqual(log.turns.count, 2)

        let notices = NoticeBox()
        let token = NotificationCenter.default.addObserver(
            forName: ChatLibraryDatedSeed.notificationName,
            object: nil,
            queue: nil
        ) { note in
            notices.record(name: note.name, object: note.object)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        library.useDatedEntryInNewChat(line: 2)

        XCTAssertEqual(notices.count, 1)
        let seed = try XCTUnwrap(notices.peek()?.object as? ChatLibraryDatedSeed)
        XCTAssertEqual(seed.scope, .entry)
        XCTAssertEqual(seed.entries.count, 1)
        XCTAssertEqual(seed.entries.first?.line, 2)
        XCTAssertEqual(seed.entries.first?.question, "Recap so far")
        XCTAssertFalse(seed.sourceText.contains("What is their objection"), "one entry does not drag the day in")
        XCTAssertTrue(try XCTUnwrap(library.notice).contains("Nothing is sent until you send it."))
    }

    /// A day whose rows all belong to saved chats is not listed as a dated log
    /// as well: one history, one place.
    func testADayOfSavedChatRowsIsNotListedAsADatedLog() async throws {
        try writeLegacyDay()
        try addLinkedProjectionDay()
        let library = await library()

        XCTAssertEqual(library.legacyLogs.map(\.id), ["2026-09-12"], "the projection-only day is not a log")
        XCTAssertEqual(library.linkedLogDayCount, 1)
        XCTAssertEqual(
            library.linkedLogNote,
            "1 day appears only as a saved chat. Its turns are listed above, not repeated as a dated log."
        )
        library.select(logID: "2026-09-12")
        XCTAssertEqual(library.openLog?.projectedTurnCount, 0, "the day that stays is the truly legacy one")
    }

    /// A mixed day keeps its truly legacy entries and hides only the rows a
    /// saved chat owns.
    func testAMixedDayShowsItsLegacyEntriesAndCountsTheRowsItHides() async throws {
        try writeLegacyDay("2026-09-12", lines: [legacyLine], extra: [
            #"{"ts":"2026-09-12T08:00:00Z","action":"Ask","userInput":"a chat's own turn","output":"already in a chat","threadID":"chat-plain"}"#,
        ])

        let library = await library()
        library.select(logID: "2026-09-12")
        let log = try XCTUnwrap(library.openLog)
        XCTAssertEqual(log.turnCount, 1)
        XCTAssertEqual(log.turns.map(\.question), ["What is their objection to the price?"])
        XCTAssertEqual(log.projectedTurnCount, 1)
        XCTAssertEqual(log.detailText, "1 turn · 1 in chats")
        XCTAssertTrue(library.legacyLogs.contains { $0.id == "2026-09-12" }, "the mixed day stays")
        XCTAssertEqual(library.linkedLogDayCount, 0)
        XCTAssertNil(library.linkedLogNote)

        // And the seed reuses only what the day still shows.
        library.select(logID: "2026-09-12")
        let seed = try XCTUnwrap(ChatLibraryDatedSeed.day(try XCTUnwrap(library.openLog)))
        XCTAssertEqual(seed.entries.map(\.line), [1])
        XCTAssertFalse(seed.sourceText.contains("already in a chat"))
    }
}

/// Collects posted notifications without capturing a non-Sendable expectation
/// in the observer closure. Guarded by its own lock.
private final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [(name: String, object: Any?)] = []

    func record(name: Notification.Name, object: Any?) {
        lock.lock()
        defer { lock.unlock() }
        notices.append((name.rawValue, object))
    }

    func peek() -> (name: String, object: Any?)? {
        lock.lock()
        defer { lock.unlock() }
        return notices.first
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return notices.count
    }
}
