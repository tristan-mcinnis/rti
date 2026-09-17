import HouseChatCore
import XCTest

/// The Chats library's rules and its read-only legacy adapter, against
/// injected temporary roots. Nothing here touches the live vault, the real
/// Application Support folder, or a stored chat.
final class ChatLibraryRulesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private var now: Date { date(9, 12, 18) }

    private func turn(
        _ role: TurnRole,
        _ text: String,
        at when: Date? = nil,
        attachments: [AttachmentRecord] = []
    ) -> TurnRecord {
        TurnRecord(role: role, text: text, createdAt: when, attachments: attachments)
    }

    private func makeRecord(
        id: String,
        title: String? = nil,
        turns: [TurnRecord] = [],
        pinned: Bool = false,
        created: Date? = nil,
        updated: Date? = nil
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            surface: .rtiCopilot,
            title: title,
            createdAt: created,
            updatedAt: updated,
            turns: turns,
            appVersion: "test",
            appPayload: pinned ? AppPayload(namespace: "rti", ["pinned": .bool(true)]) : nil
        )
    }

    private func summary(
        id: String,
        title: String? = nil,
        turnCount: Int = 0,
        bytes: Int = 100,
        issue: ConversationIssue? = nil,
        updated: Date? = nil
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            title: title,
            surface: .rtiCopilot,
            updatedAt: updated,
            turnCount: turnCount,
            byteCount: bytes,
            issue: issue
        )
    }

    // MARK: - Rows

    func testARowPrefersTheStoredNameAndFallsBackToTheFirstQuestion() {
        let named = makeRecord(
            id: "a",
            title: "  Pricing teardown  ",
            turns: [turn(.user, "what about tier three?"), turn(.assistant, "It is the busiest.")],
            updated: now
        )
        let namedRow = ChatLibraryRules.row(from: named, summary: summary(id: "a"))
        XCTAssertEqual(namedRow.title, "Pricing teardown", "a stored name wins, trimmed")
        XCTAssertTrue(namedRow.titleIsStored)
        XCTAssertNil(ChatLibraryRules.titleNote(for: namedRow))

        let unnamed = makeRecord(
            id: "b",
            turns: [turn(.assistant, "Anything else?"), turn(.user, "Compare the two plans\nsecond line")],
            updated: now
        )
        let unnamedRow = ChatLibraryRules.row(from: unnamed, summary: summary(id: "b"))
        XCTAssertEqual(unnamedRow.title, "Compare the two plans", "the fallback is the first question, one line")
        XCTAssertFalse(unnamedRow.titleIsStored)
        XCTAssertEqual(ChatLibraryRules.titleNote(for: unnamedRow), "Named from the first question")
    }

    func testALongQuestionBecomesAShortTitleAndAnEmptyChatSaysUntitled() {
        let long = String(repeating: "word ", count: 40)
        let row = ChatLibraryRules.row(
            from: makeRecord(id: "a", turns: [turn(.user, long)], updated: now),
            summary: summary(id: "a")
        )
        XCTAssertLessThanOrEqual(row.title.count, ChatLibraryRow.fallbackTitleLength + 1)
        XCTAssertTrue(row.title.hasSuffix("…"))

        let empty = ChatLibraryRules.row(from: makeRecord(id: "b", updated: now), summary: summary(id: "b"))
        XCTAssertEqual(empty.title, ChatLibraryRow.untitled)
    }

    func testRowsAreNewestFirstAndADamagedFileKeepsItsRow() {
        let old = makeRecord(id: "old", title: "Old", updated: date(9, 1, 10))
        let new = makeRecord(id: "new", title: "New", updated: date(9, 11, 10))

        let rows = ChatLibraryRules.rows(
            records: [old, new],
            summaries: [
                summary(id: "old", title: "Old", updated: date(9, 1, 10)),
                summary(id: "new", title: "New", updated: date(9, 11, 10)),
                // A file whose bytes are there but do not read: the summary
                // carries the id hint and the problem.
                summary(id: "broken", title: nil, issue: .corrupt),
            ]
        )
        XCTAssertEqual(rows.map(\.id), ["new", "old", "broken"])
        XCTAssertEqual(rows.last?.issue, .corrupt, "a damaged file is reported, not hidden")
        XCTAssertEqual(rows.last?.title, ChatLibraryRow.untitled)
        XCTAssertEqual(ChatLibraryRules.issueText(.corrupt), "Damaged file")
    }

    func testAPinIsReadFromTheRecordsOwnPayload() {
        let pinned = makeRecord(id: "a", title: "Kept", pinned: true, updated: now)
        XCTAssertTrue(ChatLibraryRules.isPinned(pinned))
        XCTAssertTrue(ChatLibraryRules.row(from: pinned, summary: nil).isPinned)
        XCTAssertFalse(ChatLibraryRules.isPinned(makeRecord(id: "b", updated: now)))
    }

    // MARK: - Search and groups

    func testSearchMatchesTheNameAndAnyTurnText() {
        let row = ChatLibraryRules.row(
            from: makeRecord(id: "a", title: "Northwind", turns: [turn(.assistant, "the loyalty card program")], updated: now),
            summary: nil
        )
        XCTAssertTrue(ChatLibraryRules.matches(row, query: ""), "an empty query matches everything")
        XCTAssertTrue(ChatLibraryRules.matches(row, query: "northwind"))
        XCTAssertTrue(ChatLibraryRules.matches(row, query: "NORTHWIND"), "case does not matter")
        XCTAssertTrue(ChatLibraryRules.matches(row, query: "loyalty card"), "every term may match anywhere")
        XCTAssertFalse(ChatLibraryRules.matches(row, query: "northwind invoice"), "one missing term means no match")
    }

    func testSectionsPutPinnedFirstAndCollapseToResultsWhileSearching() {
        let rows = [
            ChatLibraryRules.row(from: makeRecord(id: "a", title: "A", pinned: true, updated: date(9, 1, 10)), summary: nil),
            ChatLibraryRules.row(from: makeRecord(id: "b", title: "B", updated: date(9, 5, 10)), summary: nil),
            ChatLibraryRules.row(from: makeRecord(id: "c", title: "C", updated: date(9, 6, 10)), summary: nil),
        ]
        let sections = ChatLibraryRules.sections(rows: rows, query: "", isSearching: false)
        XCTAssertEqual(sections.map(\.title), ["Pinned", "Recent"])
        XCTAssertEqual(sections[0].rows.map(\.id), ["a"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["b", "c"])

        let searched = ChatLibraryRules.sections(rows: rows, query: "b", isSearching: true)
        XCTAssertEqual(searched.map(\.title), ["Results"])
        XCTAssertEqual(searched[0].rows.map(\.id), ["b"])

        let none = ChatLibraryRules.sections(rows: rows, query: "zzz", isSearching: true)
        XCTAssertTrue(none.isEmpty)
    }

    func testEmptyTextDistinguishesLoadingNoChatsAndNoMatches() {
        XCTAssertEqual(ChatLibraryRules.emptyText(hasRows: false, isSearching: false, hasLoaded: false), "Loading chats…")
        XCTAssertEqual(ChatLibraryRules.emptyText(hasRows: false, isSearching: false, hasLoaded: true), "No saved chats yet")
        XCTAssertEqual(ChatLibraryRules.emptyText(hasRows: true, isSearching: true, hasLoaded: true), "No chats match")
    }

    // MARK: - Row and header text

    func testTheRowAndHeaderLinesSayTheTurnsTimeAndDay() {
        let today = ChatLibraryRules.row(
            from: makeRecord(id: "a", title: "A", turns: [turn(.user, "hi"), turn(.assistant, "hello")], updated: date(9, 12, 15)),
            summary: nil
        )
        XCTAssertEqual(ChatLibraryRules.detail(for: today, now: now, calendar: calendar), "2 turns · 15:00")

        let earlier = ChatLibraryRules.row(
            from: makeRecord(id: "b", title: "B", turns: [turn(.user, "hi")], pinned: true, updated: date(9, 4, 9)),
            summary: nil
        )
        XCTAssertEqual(ChatLibraryRules.detail(for: earlier, now: now, calendar: calendar), "1 turn · Sep 4")
        XCTAssertEqual(
            ChatLibraryRules.headerLine(for: earlier, now: now, calendar: calendar),
            "Sep 4 09:00 · 1 turn · Pinned"
        )
    }

    func testADamagedRowSaysSoInItsLine() {
        let row = ChatLibraryRules.row(
            from: makeRecord(id: "a", title: "A", updated: now),
            summary: summary(id: "a", issue: .unsupportedSchema)
        )
        XCTAssertTrue(ChatLibraryRules.detail(for: row, now: now, calendar: calendar).contains("Newer format"))
    }

    // MARK: - Markdown export

    func testTheMarkdownExportKeepsBothSidesAndItsSources() {
        let attachment = AttachmentRecord(
            kind: .pdf,
            name: "report.pdf",
            byteCount: 2_048,
            pageCount: 12,
            contentHash: String(repeating: "a", count: 64),
            artifacts: nil
        )
        let record = makeRecord(
            id: "chat-1",
            title: "Report read",
            turns: [
                turn(.user, "what does the report say?", at: date(9, 12, 15), attachments: [attachment]),
                turn(.assistant, "The number is 42.", at: date(9, 12, 15)),
            ],
            created: date(9, 12, 15),
            updated: date(9, 12, 16)
        )
        let markdown = ChatLibraryRules.markdown(for: record)
        XCTAssertTrue(markdown.hasPrefix("# Report read"))
        XCTAssertTrue(markdown.contains("**You**"))
        XCTAssertTrue(markdown.contains("**RTI**"))
        XCTAssertTrue(markdown.contains("what does the report say?"))
        XCTAssertTrue(markdown.contains("The number is 42."))
        XCTAssertTrue(markdown.contains("- Chat ID: `chat-1`"))
        XCTAssertTrue(markdown.contains("report.pdf"))
        XCTAssertTrue(markdown.contains("PDF"))
        XCTAssertTrue(markdown.contains("2 KB"))
        XCTAssertTrue(markdown.contains("aaaaaaa…"), "the hash is shown short")
    }

    // MARK: - Sources

    func testSourcesReportTheWorstStateAcrossAnAttachmentsCopies() async {
        let hash = String(repeating: "b", count: 64)
        let attachment = AttachmentRecord(
            kind: .pdf,
            name: "report.pdf",
            byteCount: 10,
            contentHash: hash,
            path: "/tmp/report.pdf",
            artifacts: AttachmentArtifacts(
                original: ArtifactRef(kind: .original, sha256: hash, byteCount: 10, fileExtension: "pdf"),
                extractedText: ArtifactRef(kind: .extractedText, sha256: String(repeating: "c", count: 64), byteCount: 8, fileExtension: "txt")
            )
        )
        let record = makeRecord(id: "a", title: "A", turns: [turn(.user, "read this", attachments: [attachment])], updated: now)

        let verified = await ChatLibraryRules.sources(for: record) { _ in .verified }
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified[0].state, .verified)
        XCTAssertEqual(verified[0].archivedCopies, 2)
        XCTAssertEqual(verified[0].factsText, "PDF · 10 bytes", "what the source is, not its state")
        XCTAssertEqual(verified[0].detailText, "2 saved copies, present and matching.", "the hash has its own line, so it is not repeated here")
        XCTAssertEqual(verified[0].sourcePath, "/tmp/report.pdf", "the record's path is shown, never read")

        // One copy is gone: the source is reported as missing, not as verified.
        let missing = await ChatLibraryRules.sources(for: record) { ref in
            ref.kind == .original ? .verified : .missing
        }
        XCTAssertEqual(missing[0].state, .missing)
        XCTAssertEqual(missing[0].stateText, "Missing")

        // The original hashes to something else.
        let mismatched = await ChatLibraryRules.sources(for: record) { ref in
            ref.kind == .original ? .mismatched(actualSHA256: String(repeating: "d", count: 64)) : .verified
        }
        XCTAssertEqual(mismatched[0].state, .mismatched(actualSHA256: String(repeating: "d", count: 64)))
        XCTAssertTrue(mismatched[0].detailText.contains("dddddddd…"))
    }

    func testASourceWithNoArchivedCopySaysSoAndAnUnknownKindIsUnverifiable() async {
        let bare = AttachmentRecord(kind: .image, name: "shot.png", byteCount: 100, artifacts: nil)
        let record = makeRecord(id: "a", title: "A", turns: [turn(.user, "look", attachments: [bare])], updated: now)
        let sources = await ChatLibraryRules.sources(for: record) { _ in .verified }
        XCTAssertEqual(sources[0].state, .noArchive)
        XCTAssertNil(sources[0].contentHash, "an image has no hash, and the row still reads")
        XCTAssertEqual(sources[0].stateText, "No saved copy")

        let unknown = AttachmentRecord(
            kind: .other,
            kindRaw: "hologram",
            name: "thing.holo",
            byteCount: 3,
            artifacts: AttachmentArtifacts(
                original: ArtifactRef(kind: .unknown, kindRaw: "hologram", sha256: String(repeating: "e", count: 64), byteCount: 3)
            )
        )
        let second = makeRecord(id: "b", title: "B", turns: [turn(.user, "and this", attachments: [unknown])], updated: now)
        let checked = await ChatLibraryRules.sources(for: second) { _ in .verified }
        XCTAssertEqual(checked[0].state, .unverifiable("The record names a kind of copy this build cannot read (hologram)."))
    }

    // MARK: - Storage display

    func testTheStorageLineAndShortHash() {
        XCTAssertNil(ChatLibraryFormat.storageLine(chats: 0, legacyLogs: 0, bytes: nil), "an unknown size is not a zero")
        XCTAssertEqual(ChatLibraryFormat.storageLine(chats: 1, legacyLogs: 0, bytes: 2_048), "1 saved chat · 2 KB of saved copies")
        XCTAssertEqual(ChatLibraryFormat.storageLine(chats: 2, legacyLogs: 1, bytes: 2_048), "2 saved chats · 1 dated log · 2 KB of saved copies")
        XCTAssertEqual(ChatLibraryFormat.compactStorageLine(chats: 2, legacyLogs: 1, bytes: 2_048), "2 chats · 1 log · 2 KB")
        XCTAssertNil(ChatLibraryFormat.compactStorageLine(chats: 0, legacyLogs: 0, bytes: nil))
        XCTAssertEqual(ChatLibraryFormat.countsLine(chats: 2, legacyLogs: 1), "2 chats · 1 log")
        XCTAssertEqual(ChatLibraryFormat.chatCount(1), "1 chat")
        XCTAssertEqual(ChatLibraryFormat.shortHash(String(repeating: "f", count: 64)), "ffffffff…")
        XCTAssertEqual(ChatLibraryFormat.shortHash("abc"), "abc")
    }
}

/// The legacy daily turn logs: dated entries read honestly, never rewritten,
/// and never assembled into a chat that never existed.
final class ChatLibraryLegacyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One stored line, written the way `VaultLogStore` writes it: one JSON
    /// object on one line, with the fields the library does not keep
    /// (`transcriptContext`, the full tool records) present too.
    /// "15:04" for a stored UTC stamp, in this Mac's zone. The log stamps in
    /// UTC; the library shows local time, so the test asks for the same.
    private func localTime(_ iso: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: ISO8601DateFormatter().date(from: iso)!)
    }

    /// The day logs, read through the actor.
    private func logs() async -> [ChatLibraryLegacy.Log] {
        await ChatLibraryLegacyReader(root: root).logs()
    }

    private func line(
        ts: String,
        action: String = "Ask",
        userInput: String,
        output: String,
        inSession: Bool = false,
        threadID: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "ts": ts,
            "action": action,
            "mode": NSNull(),
            "provider": "deepseek",
            "model": "deepseek-chat",
            "smart": false,
            "inSession": inSession,
            "contextUsed": false,
            "screenUsed": false,
            "userInput": userInput,
            "transcriptContext": "a whole transcript the library must not keep",
            "output": output,
            "sources": ["northwind-brief.md"],
            "toolCalls": [[
                "name": "read_document",
                "arguments": "{}",
                "status": "ok",
                "elapsedMS": 12,
                "resultCharacters": 3,
            ]],
        ]
        // A newer row also names the saved chat it belongs to; such a row is a
        // projection of a thread, not a dated entry of its own.
        if let threadID { object["threadID"] = threadID }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testADaysLogReadsAsDatedTurnsNewestDayFirst() async throws {
        _ = try write("2026-09-10.jsonl", [line(ts: "2026-09-10T02:00:00Z", userInput: "older day", output: "ok"), ""].joined(separator: "\n"))
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "first question", output: "first answer"),
            line(ts: "2026-09-12T07:30:00Z", action: "Recap", userInput: "what changed?", output: "second answer", inSession: true),
            "",
        ].joined(separator: "\n"))
        _ = try write("notes.txt", "not a log")

        let logs = await ChatLibraryLegacyReader(root: root).logs()
        XCTAssertEqual(logs.map(\.id), ["2026-09-12", "2026-09-10"], "the newest day comes first")
        XCTAssertEqual(logs[0].turnCount, 2)
        XCTAssertEqual(logs[0].turns.map(\.question), ["first question", "what changed?"])
        XCTAssertEqual(logs[0].turns.map(\.answer), ["first answer", "second answer"])
        XCTAssertEqual(logs[0].turns[1].action, "Recap")
        XCTAssertEqual(logs[0].turns[1].toolNames, ["read_document"])
        XCTAssertTrue(logs[0].turns[1].detailText.contains("Recap"))
        XCTAssertTrue(logs[0].turns[1].detailText.contains("Live session"))
        XCTAssertEqual(logs[0].turns[0].id, 1, "the id is the line number, so a dated entry is stable")
        XCTAssertEqual(logs[0].turns[1].id, 2)
        XCTAssertEqual(logs[0].detailText, "2 turns")
        XCTAssertEqual(logs[0].title, "12 Sep 2026")
    }

    func testABadLineIsCountedAndTheRestOfTheDayStillReads() async throws {
        let body = [
            line(ts: "2026-09-12T07:04:00Z", userInput: "kept", output: "answer"),
            "{ not json",
            "{\"ts\":\"2026-09-12T07:10:00Z\",\"userInput\":\"\",\"output\":\"\"}",
            line(ts: "2026-09-12T07:12:00Z", userInput: "also kept", output: "answer"),
            "",
        ].joined(separator: "\n")
        _ = try write("2026-09-12.jsonl", body)

        let logs = await ChatLibraryLegacyReader(root: root).logs()
        XCTAssertEqual(logs[0].turnCount, 2)
        XCTAssertEqual(logs[0].skippedLines, 2, "a line that does not decode, and one with no turn in it")
        XCTAssertEqual(logs[0].turns.map(\.question), ["kept", "also kept"])
        XCTAssertEqual(logs[0].detailText, "2 turns · 2 lines skipped")
    }

    func testAnUnreadableDayIsReportedRatherThanSkipped() async throws {
        let url = try write("2026-09-12.jsonl", "irrelevant")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        let logs = await ChatLibraryLegacyReader(root: root).logs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].turnCount, 0)
        if case .read = logs[0].state { XCTFail("an unreadable file is not a read file") }
    }

    /// The whole point of the adapter: it never writes.
    func testScanningTheLogsLeavesEveryByteInPlace() async throws {
        let first = try write("2026-09-11.jsonl", line(ts: "2026-09-11T02:00:00Z", userInput: "one", output: "two") + "\n")
        let second = try write("2026-09-12.jsonl", [line(ts: "2026-09-12T07:04:00Z", userInput: "three", output: "four"), ""].joined(separator: "\n"))
        let before = try [first, second].map { ($0.lastPathComponent, try Data(contentsOf: $0), try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) }

        _ = await ChatLibraryLegacyReader(root: root).logs()

        for (index, entry) in before.enumerated() {
            let url = index == 0 ? first : second
            XCTAssertEqual(try Data(contentsOf: url), entry.1, "\(entry.0) is unchanged")
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                entry.2,
                "\(entry.0) keeps its timestamp"
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["2026-09-11.jsonl", "2026-09-12.jsonl"],
            "the scan creates nothing"
        )
    }

    func testTheLogsFolderThatIsNotThereIsAnEmptyLibrary() async throws {
        let missing = root.appendingPathComponent("nothing-here", isDirectory: true)
        let logs = await ChatLibraryLegacyReader(root: missing).logs()
        XCTAssertTrue(logs.isEmpty)
    }

    // MARK: - Saved-chat projection rows

    /// A row that names a saved chat is that chat's projection: it is counted
    /// and left out, so one history is never listed twice. The rows that carry
    /// no thread id are shown exactly as recorded.
    func testALinkedRowIsNotShownTwiceAndUnlinkedRowsStayExactlyAsRecorded() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "truly legacy", output: "legacy answer"),
            line(ts: "2026-09-12T08:00:00Z", userInput: "belongs to a chat", output: "chat answer", threadID: "chat-1"),
            line(ts: "2026-09-12T09:00:00Z", userInput: "legacy again", output: "another answer"),
            "",
        ].joined(separator: "\n"))

        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        XCTAssertEqual(log.turns.map(\.question), ["truly legacy", "legacy again"])
        XCTAssertEqual(log.turns.map(\.answer), ["legacy answer", "another answer"])
        XCTAssertEqual(log.turns.map(\.id), [1, 3], "the recorded line numbers are kept")
        XCTAssertEqual(log.projectedTurnCount, 1)
        XCTAssertEqual(log.detailText, "2 turns · 1 in chats")
        XCTAssertEqual(
            log.projectionNote,
            "1 row from this day belongs to saved chats. They are listed under Chats, not repeated here."
        )
        XCTAssertFalse(log.isEntirelyProjected)
        XCTAssertNil(log.turns.first(where: { $0.isProjectionOfSavedChat }), "no projection is ever shown")
    }

    func testADayThatIsOnlySavedChatsIsCountedAndHasNothingOfItsOwn() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "one", output: "answer", threadID: "chat-1"),
            line(ts: "2026-09-12T07:30:00Z", userInput: "two", output: "answer", threadID: "chat-1"),
            "",
        ].joined(separator: "\n"))

        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        XCTAssertTrue(log.isEntirelyProjected)
        XCTAssertTrue(log.turns.isEmpty)
        XCTAssertEqual(log.projectedTurnCount, 2)
        XCTAssertEqual(log.detailText, "0 turns · 2 in chats")
    }

    // MARK: - Reusing a dated log in a new chat

    func testTheDaySeedCarriesEveryDisplayedDatedEntryInOrder() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", action: "Assist", userInput: "first question", output: "first answer"),
            line(ts: "2026-09-12T07:30:00Z", userInput: "hidden chat row", output: "hidden", threadID: "chat-1"),
            line(ts: "2026-09-12T08:00:00Z", action: "Recap", userInput: "second question", output: "second answer", inSession: true),
            "",
        ].joined(separator: "\n"))

        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        let seed = try XCTUnwrap(ChatLibraryDatedSeed.day(log))

        XCTAssertEqual(seed.id, "legacy-day-2026-09-12")
        XCTAssertEqual(seed.day, "2026-09-12")
        XCTAssertEqual(seed.scope, .day)
        XCTAssertEqual(seed.title, "12 Sep 2026")
        XCTAssertEqual(seed.sourcePath, log.sourcePath, "the log file is carried as a reference")
        XCTAssertEqual(seed.entries.map(\.line), [1, 3])
        XCTAssertEqual(seed.entries.map(\.question), ["first question", "second question"])
        XCTAssertEqual(seed.entries.map(\.day), ["2026-09-12", "2026-09-12"])
        XCTAssertEqual(seed.entries.last?.inSession, true)
        XCTAssertEqual(seed.entries.first?.sources, ["northwind-brief.md"], "what the log recorded, not an original this library holds")
        XCTAssertEqual(seed.entries.first?.tools, ["read_document"])

        // The attached text is the recorded material: dated, in order, never
        // merged, and never carrying the transcript that was attached live.
        let text = seed.sourceText
        XCTAssertTrue(text.hasPrefix("## Dated log, 12 Sep 2026"))
        XCTAssertTrue(text.contains("not a saved chat"))
        XCTAssertTrue(text.contains("### \(localTime("2026-09-12T07:04:00Z")) · Assist"))
        XCTAssertTrue(text.contains("**Asked:** first question"))
        XCTAssertTrue(text.contains("**Answered:** first answer"))
        XCTAssertTrue(text.contains("### \(localTime("2026-09-12T08:00:00Z")) · Recap · live session"))
        XCTAssertFalse(text.contains("hidden"), "a saved chat's projection row is not reused")
        XCTAssertFalse(text.contains("a whole transcript the library must not keep"))
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "first question")).lowerBound,
            try XCTUnwrap(text.range(of: "second question")).lowerBound,
            "entries keep their recorded order"
        )

        XCTAssertEqual(seed.prompt, "About this dated log (12 Sep 2026, 2 entries): ", "an editable draft, and nothing is sent")
    }

    func testAnEntrySeedCarriesOnlyThatEntryAndNamesItsLine() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "first question", output: "first answer"),
            line(ts: "2026-09-12T07:30:00Z", userInput: "second question", output: "second answer"),
            "",
        ].joined(separator: "\n"))

        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        let entry = try XCTUnwrap(log.turns.last)
        let seed = try XCTUnwrap(ChatLibraryDatedSeed.entry(entry, in: log))

        XCTAssertEqual(seed.id, "legacy-entry-2026-09-12-2")
        XCTAssertEqual(seed.scope, .entry)
        XCTAssertEqual(seed.title, "12 Sep 2026 · \(localTime("2026-09-12T07:30:00Z"))")
        XCTAssertEqual(seed.entries.count, 1)
        XCTAssertEqual(seed.entries.first?.line, 2)
        XCTAssertEqual(seed.entries.first?.question, "second question")
        XCTAssertFalse(seed.sourceText.contains("first question"), "one entry means one entry")
        XCTAssertEqual(seed.prompt, "About this dated entry (12 Sep 2026 · \(localTime("2026-09-12T07:30:00Z"))): ")
    }

    func testASavedChatRowCannotBeReusedAsIfItWereDated() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "legacy", output: "answer"),
            line(ts: "2026-09-12T07:30:00Z", userInput: "projected", output: "answer", threadID: "chat-1"),
            "",
        ].joined(separator: "\n"))

        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        // The projection row is not in the displayed entries, so nothing can
        // seed it: an entry seed needs a turn the day actually shows.
        XCTAssertEqual(log.turns.count, 1)
        let hiddenJSON = line(
            ts: "2026-09-12T07:30:00Z",
            userInput: "projected",
            output: "answer",
            threadID: "chat-1"
        )
        let hiddenRow = try JSONDecoder()
            .decode(ChatLibraryLegacy.Turn.self, from: Data(hiddenJSON.utf8))
            .with(id: 2)
        XCTAssertTrue(hiddenRow.isProjectionOfSavedChat)
        XCTAssertNil(ChatLibraryDatedSeed.entry(hiddenRow, in: log))

        let day = try XCTUnwrap(ChatLibraryDatedSeed.day(log))
        XCTAssertEqual(day.entries.map(\.line), [1])
        XCTAssertFalse(day.sourceText.contains("projected"))
    }

    func testADayWithNothingToReuseSeedsNothing() async throws {
        _ = try write("2026-09-12.jsonl", [
            line(ts: "2026-09-12T07:04:00Z", userInput: "legacy", output: "answer"),
            "",
        ].joined(separator: "\n"))
        let loaded = await logs()
        let log = try XCTUnwrap(loaded.first)
        XCTAssertNil(ChatLibraryDatedSeed.day(ChatLibraryLegacy.Log.unreadable(day: "2026-09-11", reason: "gone")))
        XCTAssertNotNil(ChatLibraryDatedSeed.day(log))
    }

    func testTheOrientationLineNeverClaimsTheDayWasOneChat() {
        let log = ChatLibraryLegacy.Log(
            day: "2026-09-12",
            sourcePath: "/tmp/turns/2026-09-12.jsonl",
            turns: [],
            projectedTurnCount: 0,
            skippedLines: 0,
            state: .read(skippedLines: 0)
        )
        XCTAssertTrue(log.orientationText.contains("not a saved chat"))
        XCTAssertTrue(log.orientationText.contains("nothing says where one chat ended"))
    }
}

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

/// One proof the plan asks for by name: deleting a chat deletes the chat and
/// the copies only it owned, and never a linked recording or the user's own
/// file.
final class ChatLibraryDeletionTests: XCTestCase {
    private var root: URL!
    private var configHome: TempConfigHome?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The store's deletion resolves the vault itself; keep it in here.
        configHome = try TempConfigHome(under: root)
    }

    override func tearDownWithError() throws {
        configHome?.restore()
        configHome = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testDeletingAChatKeepsLinkedRecordingsAndTheOriginalFile() async throws {
        let store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true)
        ))

        // Two files a chat never owns: the meeting recording and the user's
        // own document. The record points at both by reference.
        let recording = root.appendingPathComponent("audio-mic.wav")
        let recordingBytes = Data("RIFF....a meeting's audio".utf8)
        try recordingBytes.write(to: recording)

        let original = root.appendingPathComponent("report.pdf")
        let originalBytes = Data("%PDF-1.4 the user's own document".utf8)
        try originalBytes.write(to: original)

        let conversation = try await store.thread(
            id: "chat-1",
            title: "Report read",
            surface: .rtiCopilot,
            session: SessionLink(kind: "rti-session", id: "2026-09-12 150000", label: "Pricing teardown"),
            appVersion: "test"
        )
        let committed = try await store.appendTurn(to: conversation, turn: ChatThreadStore.SubmittedTurn(
            text: "what does the report say?",
            attachments: [ChatThreadStore.SubmittedAttachment(
                kind: .pdf,
                name: "report.pdf",
                path: original.path,
                byteCount: originalBytes.count,
                pageCount: 12,
                originalBytes: originalBytes,
                originalExtension: "pdf",
                extractedText: "The number is 42."
            )]
        ))
        let hash = try XCTUnwrap(committed.conversation.turns.last?.attachments.first?.contentHash)

        _ = try await store.delete(id: "chat-1")

        XCTAssertFalse(store.contains(id: "chat-1"), "the chat's own record is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path), "the linked recording is kept")
        XCTAssertEqual(try Data(contentsOf: recording), recordingBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the user's own file is kept")
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)

        // And the chat's own archived copies are gone with it.
        let remaining = try await store.artifacts()
        XCTAssertFalse(remaining.contains { $0.sha256 == hash && $0.kind == .original })
        let left = try await store.summaries()
        XCTAssertTrue(left.isEmpty)
    }

    func testAChatThatIsStillStoredKeepsItsBytesEvenAfterASiblingIsDeleted() async throws {
        let store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true)
        ))
        let bytes = Data("shared bytes".utf8)
        func submission() -> ChatThreadStore.SubmittedTurn {
            ChatThreadStore.SubmittedTurn(
                text: "read this",
                attachments: [ChatThreadStore.SubmittedAttachment(
                    kind: .text, name: "shared.txt", byteCount: bytes.count,
                    originalBytes: bytes, originalExtension: "txt"
                )]
            )
        }
        for id in ["chat-1", "chat-2"] {
            let conversation = try await store.thread(id: id, title: nil, surface: .rtiCopilot, session: nil, appVersion: nil)
            _ = try await store.appendTurn(to: conversation, turn: submission())
        }
        _ = try await store.delete(id: "chat-1")
        let survivorRecord = try await store.load(id: "chat-2")
        let survivor = try XCTUnwrap(survivorRecord.turns.last?.attachments.first)
        let ref = try XCTUnwrap(survivor.artifacts?.original)
        let restored = try await store.read(ref)
        XCTAssertEqual(restored, bytes, "a sibling that still points at the bytes keeps them")
    }
}
