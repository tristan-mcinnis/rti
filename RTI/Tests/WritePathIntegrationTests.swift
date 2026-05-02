import XCTest

/// Integration test for the session-end write path. Stands in for the
/// manual smoke ("start a session, speak, end it, check ~/meetings/")
/// without requiring a microphone, network, Soniox, or DeepSeek.
///
/// Drives the same code path that runs at session-end:
///   1. JSONL events synthesised in a temp file (as if a live session
///      had streamed words + notes)
///   2. `LiveJSONLReader` parses them back
///   3. `MarkdownRenderer.turns(from:)` collapses to TurnLines (the
///      same conversion `CorpusManager.renderSession` uses)
///   4. `MarkdownRenderer.make` renders frontmatter + body
///   5. `CorpusWriter.write` lands the file atomically
///   6. `CorpusReader.read` round-trips the file back
///   7. assertions on every layer
final class WritePathIntegrationTests: XCTestCase {

    private var tmpRoot: URL!
    private var corpusDir: URL!
    private var jsonlURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-write-\(UUID().uuidString)")
        corpusDir = tmpRoot.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: corpusDir, withIntermediateDirectories: true)
        jsonlURL = tmpRoot.appendingPathComponent("session.jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        try await super.tearDown()
    }

    // MARK: - synthesise + render + verify

    func test_endToEnd_fromJSONLToMarkdown_roundTrips() throws {
        let writer = LiveJSONLWriter(url: jsonlURL)
        try writer.open()

        // Simulate ~30 seconds of mic + system audio with a note in the
        // middle. Two same-speaker words become one turn; a different
        // speaker breaks the run.
        writer.append(.word(ts: 0,    speaker: 0, text: "Hello ",  isFinal: true, confidence: 0.95, channel: "mic"))
        writer.append(.word(ts: 800,  speaker: 0, text: "everyone", isFinal: true, confidence: 0.92, channel: "mic"))
        writer.append(.word(ts: 2_500, speaker: 1, text: "hi back", isFinal: true, confidence: 0.91, channel: "system"))
        writer.append(.note(ts: 5_000, text: "alex committed to a draft by Friday"))
        writer.append(.word(ts: 7_000, speaker: 0, text: "OK ",     isFinal: true, confidence: 0.93, channel: "mic"))
        writer.append(.word(ts: 7_500, speaker: 0, text: "great",   isFinal: true, confidence: 0.94, channel: "mic"))
        // Non-final word should be ignored.
        writer.append(.word(ts: 8_000, speaker: 0, text: "filler",  isFinal: false, confidence: 0.5, channel: "mic"))
        writer.close()

        // Read back via the same path CorpusManager uses.
        let events = try LiveJSONLReader.readAll(jsonlURL)
        XCTAssertEqual(events.count, 7, "all 7 events should round-trip including non-final")

        let turns = MarkdownRenderer.turns(from: events)
        // 4 turns: self(1+2 grouped), them_1, note, self(grouped). Non-final dropped.
        XCTAssertEqual(turns.count, 4, "Expected: 2 same-speaker grouped, 1 system, 1 note, 2 same-speaker grouped")
        XCTAssertEqual(turns[0].speakerId, "self")
        XCTAssertEqual(turns[0].text, "Hello everyone")
        XCTAssertEqual(turns[1].speakerId, "them_1")
        XCTAssertEqual(turns[2].speakerId, "note")
        XCTAssertEqual(turns[2].text, "alex committed to a draft by Friday")
        XCTAssertEqual(turns[3].speakerId, "self")
        XCTAssertEqual(turns[3].text, "OK great")

        // Render with synthetic title + summary as if SessionTitleController
        // and SummaryController had populated their caches.
        let startedAt = Date(timeIntervalSince1970: 1_714_656_000)
        let inputs = MarkdownRenderer.Inputs(
            id: "synth-session-1",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2520),
            title: "Sync with Alex",
            modeId: "sales",
            transcriptQuality: "realtime",
            wavPath: "/tmp/synth.wav",
            attendees: ["You", "Alex"],
            speakerMap: ["self": .init(name: "You", source: "deterministic"),
                         "them_1": .init(name: "Alex", source: "llm")],
            keyTopics: ["scheduling", "draft"],
            summaryMarkdown: "## Summary\nDiscussed timing.\n\n## Action Items\n- [ ] Alex sends draft Friday",
            turns: turns
        )
        let entry = MarkdownRenderer.make(inputs)
        let url = try CorpusWriter.write(entry, to: corpusDir, slug: "sync-with-alex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Re-parse the file and assert structure.
        let reparsed = try CorpusReader.read(url)
        XCTAssertEqual(reparsed.frontmatter.id, "synth-session-1")
        XCTAssertEqual(reparsed.frontmatter.title, "Sync with Alex")
        XCTAssertEqual(reparsed.frontmatter.duration, "42m")
        XCTAssertEqual(reparsed.frontmatter.attendees, ["You", "Alex"])
        XCTAssertEqual(reparsed.frontmatter.speakerMap?["self"]?.name, "You")
        XCTAssertEqual(reparsed.frontmatter.speakerMap?["them_1"]?.name, "Alex")
        XCTAssertEqual(reparsed.frontmatter.keyTopics, ["scheduling", "draft"])

        // Body should contain Summary, Action Items, and Transcript sections,
        // and the transcript lines should be in the right order.
        XCTAssertTrue(reparsed.body.contains("## Summary"))
        XCTAssertTrue(reparsed.body.contains("Discussed timing."))
        XCTAssertTrue(reparsed.body.contains("## Action Items"))
        XCTAssertTrue(reparsed.body.contains("- [ ] Alex sends draft Friday"))
        XCTAssertTrue(reparsed.body.contains("## Transcript"))
        XCTAssertTrue(reparsed.body.contains("[self 0:00] Hello everyone"))
        XCTAssertTrue(reparsed.body.contains("[them_1 0:02] hi back"))
        XCTAssertTrue(reparsed.body.contains("[note 0:05] alex committed to a draft by Friday"))
        XCTAssertTrue(reparsed.body.contains("[self 0:07] OK great"))
    }

    func test_emptyJSONL_producesNoTurns() throws {
        let writer = LiveJSONLWriter(url: jsonlURL)
        try writer.open()
        writer.close()
        let events = try LiveJSONLReader.readAll(jsonlURL)
        XCTAssertEqual(MarkdownRenderer.turns(from: events).count, 0)
    }

    func test_chatEventsSkipped() throws {
        let writer = LiveJSONLWriter(url: jsonlURL)
        try writer.open()
        writer.append(.word(ts: 0, speaker: 0, text: "hi", isFinal: true, confidence: 1, channel: "mic"))
        writer.append(.chat(ts: 1_000, role: "user", content: "what just happened"))
        writer.append(.chat(ts: 2_000, role: "assistant", content: "they said hi"))
        writer.close()

        let events = try LiveJSONLReader.readAll(jsonlURL)
        let turns = MarkdownRenderer.turns(from: events)
        // Chat events are NOT transcript turns — only the one word survives.
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "hi")
    }

    func test_systemSpeaker0_labelledThem() throws {
        let writer = LiveJSONLWriter(url: jsonlURL)
        try writer.open()
        writer.append(.word(ts: 0, speaker: 0, text: "yo", isFinal: true, confidence: 1, channel: "system"))
        writer.close()
        let events = try LiveJSONLReader.readAll(jsonlURL)
        let turns = MarkdownRenderer.turns(from: events)
        XCTAssertEqual(turns.first?.speakerId, "them",
            "system audio's speaker 0 should label as 'them' (not 'self' — the local mic owns 'self').")
    }
}
