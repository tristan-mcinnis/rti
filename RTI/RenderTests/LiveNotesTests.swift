import RTICore
import XCTest

/// Live Notes: the controller's output parsing, the settings keys that carry
/// over from earlier builds, the tab's visibility rule, and the notes.md
/// the archive writes at stop.
@MainActor
final class LiveNotesTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try RenderProofHarness.prepare()
    }

    func testParseSplitsTheTitleLineFromTheBullets() {
        let parsed = NotesGenerationController.parse("TITLE: Pricing tiers\n- Three tiers\n\n- FAQ moves under the table")
        XCTAssertEqual(parsed.title, "Pricing tiers")
        XCTAssertEqual(parsed.bullets, "- Three tiers\n- FAQ moves under the table")
    }

    func testParseWithoutATitleKeepsEveryBullet() {
        let parsed = NotesGenerationController.parse("- One\n- Two")
        XCTAssertEqual(parsed.title, "")
        XCTAssertEqual(parsed.bullets, "- One\n- Two")
    }

    func testSettingsKeepTheStoredKeyNames() {
        XCTAssertEqual(NotesSettings.enabledKey, "rti.analysis.notesEnabled")
        XCTAssertEqual(NotesSettings.intervalKey, "rti.analysis.notesIntervalSeconds")
        XCTAssertTrue(NotesSettings.defaultEnabled)
        XCTAssertEqual(NotesSettings.defaultInterval, 120)
        XCTAssertEqual(NotesSettings.intervalRange, 60...600)
    }

    func testSchedulerTickFollowsTheSavedNotesInterval() {
        let key = NotesSettings.intervalKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(300.0, forKey: key)
        XCTAssertEqual(NotesSettings.tickInterval, 300)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(NotesSettings.tickInterval, NotesSettings.defaultInterval)
    }

    func testNotesTabShowsOnlyWhenEnabledAndSitsLast() {
        XCTAssertEqual(OverlayTab.visibleTabs(notes: true, auto: false), [.assist, .transcript, .notes])
        XCTAssertEqual(OverlayTab.visibleTabs(notes: true, auto: true), [.assist, .auto, .transcript, .notes])
        XCTAssertEqual(OverlayTab.visibleTabs(notes: false, auto: false), [.assist, .transcript])
    }

    func testTheArchiveWritesNotesMdAndTheSidecarCarriesThem() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(240)
        let notes = [
            GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 120_000, title: "Launch timing", content: "- The tour costs a sprint."),
            GeneratedNote(timestamp: endedAt, rangeStartMs: 120_000, rangeEndMs: 240_000, title: "", content: "- Ship without it."),
        ]
        let dir = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt,
            endedAt: endedAt,
            transcript: [],
            chat: [],
            notes: notes
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let written = try String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(written.contains("# Notes"))
        XCTAssertTrue(written.contains("### 0:00 – 2:00 · Launch timing\n\n- The tour costs a sprint."))
        XCTAssertTrue(written.contains("### 2:00 – 4:00\n\n- Ship without it."))

        let sidecar = try XCTUnwrap(SessionArchive.writeCanonicalMeetingSidecar(
            startedAt: startedAt,
            chat: [],
            visualContext: [],
            notes: notes,
            archiveDir: dir,
            callType: .client,
            typedNotes: [LiveEntry(speakerId: "note", text: "Ask about the\nbudget", startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)]
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: sidecar) }
        let sidecarText = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(sidecarText.contains("## My notes\n\n- Ask about the budget\n"))
        XCTAssertTrue(sidecarText.contains("## Generated notes"))
        XCTAssertTrue(sidecarText.contains("### 0:00 – 2:00 · Launch timing"))
    }

    func testNoNotesMeansNoNotesFile() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let entry = LiveEntry(speakerId: "self", text: "Hello there", startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        let dir = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry],
            chat: []
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path))
    }

    func testTheSessionsWindowListsNotesFirst() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_200_000)
        let notes = [GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000, title: "A", content: "- b")]
        let entry = LiveEntry(speakerId: "self", text: "Hello there", startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        let dir = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry],
            chat: [],
            notes: notes
        ))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let session = try XCTUnwrap(SessionArchive.recentSessions(limit: 200).first { $0.url.standardizedFileURL == dir.standardizedFileURL })
        let files = SessionsWindowModel.files(for: session)
        XCTAssertEqual(Array(files.map(\.name).prefix(2)), ["notes", "transcript"])
        XCTAssertEqual(files.first?.displayName, "Notes")
    }
}

// Suspends provider completions explicitly; no sleeps, network, or timing races.
private actor GenerationResponseGate {
    private var calls: [CheckedContinuation<LLMClient.CollectedResponse, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func collect() async -> LLMClient.CollectedResponse {
        await withCheckedContinuation { continuation in
            calls.append(continuation)
            let ready = waiters.filter { $0.0 <= calls.count }
            waiters.removeAll { $0.0 <= calls.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int, text: String) {
        calls[index].resume(returning: LLMClient.CollectedResponse(
            text: text, finishReason: "stop", reasoningCharacters: 0
        ))
    }
}

extension LiveNotesTests {
    func testOldNotesCompletionCannotReleaseNewSessionPassOrSetItsError() async {
        seedGenerationTranscript()
        defer { clearGenerationTranscript() }
        let gate = GenerationResponseGate()
        let controller = NotesGenerationController(request: generationRequest(gate))
        controller.reset(for: "old")
        async let old = controller.generate(sessionId: "old")
        await gate.waitForCalls(1)
        controller.reset(for: "new")
        async let current = controller.generate(sessionId: "new")
        await gate.waitForCalls(2)

        await gate.finish(0, text: "")
        _ = await old
        XCTAssertTrue(controller.isGenerating)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.notes.isEmpty)
        if controller.isGenerating {
            let overlapping = await controller.generate(sessionId: "new")
            XCTAssertNil(overlapping)
        }

        await gate.finish(1, text: "TITLE: Current session\n- Current note")
        _ = await current
        XCTAssertFalse(controller.isGenerating)
        XCTAssertEqual(controller.notes.map(\.title), ["Current session"])
    }

    func testOldAutoCompletionCannotReleaseNewSessionPass() async {
        seedGenerationTranscript()
        defer { clearGenerationTranscript() }
        let gate = GenerationResponseGate()
        let controller = AutoAssistController(request: generationRequest(gate))
        controller.reset(for: "old")
        async let old = controller.generate(sessionId: "old")
        await gate.waitForCalls(1)
        controller.reset(for: "new")
        async let current = controller.generate(sessionId: "new")
        await gate.waitForCalls(2)

        await gate.finish(0, text: "[]")
        _ = await old
        XCTAssertTrue(controller.isGenerating)
        XCTAssertTrue(controller.cards.isEmpty)
        if controller.isGenerating {
            let overlapping = await controller.generate(sessionId: "new")
            XCTAssertNil(overlapping)
        }

        await gate.finish(1, text: "[]")
        _ = await current
        XCTAssertFalse(controller.isGenerating)
    }

    func testClearedNotesIgnoreLateFailureAndCanRetryCurrentFailure() async {
        seedGenerationTranscript()
        defer { clearGenerationTranscript() }
        let gate = GenerationResponseGate()
        let controller = NotesGenerationController(request: generationRequest(gate))
        controller.reset(for: "old")
        async let old = controller.generate(sessionId: "old")
        await gate.waitForCalls(1)
        controller.clear()
        await gate.finish(0, text: "")
        _ = await old
        XCTAssertNil(controller.lastError)
        XCTAssertFalse(controller.isGenerating)

        controller.reset(for: "new")
        async let failed = controller.generate(sessionId: "new")
        await gate.waitForCalls(2)
        await gate.finish(1, text: "")
        _ = await failed
        XCTAssertNotNil(controller.lastError)
        XCTAssertFalse(controller.isGenerating)
        async let retry = controller.generate(sessionId: "new")
        await gate.waitForCalls(3)
        await gate.finish(2, text: "TITLE: Retry\n- Retained window")
        _ = await retry
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.notes.map(\.title), ["Retry"])
    }

    private func generationRequest(_ gate: GenerationResponseGate) -> LLMRequest {
        LLMRequest(collectStream: { _, _, _, _ in await gate.collect() }, priority: .foreground,
                   admission: LLMAdmissionController())
    }

    private func seedGenerationTranscript() {
        MeetingContextStore.shared.resetAfterSession()
        SessionCoordinator.shared.seedForRenderProof(
            entries: [LiveEntry(speakerId: "self", text: "Discuss the next milestone", startMs: 1000,
                                confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)],
            interim: nil, phase: .idle, startedAt: nil
        )
    }

    private func clearGenerationTranscript() {
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
    }
}
