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
        XCTAssertEqual(OverlayTab.visibleTabs(notes: true), [.assist, .transcript, .notes])
        XCTAssertEqual(OverlayTab.visibleTabs(notes: false), [.assist, .transcript])
        XCTAssertEqual(OverlayTab.visibleTabs(notes: true, codebook: true), [.assist, .transcript, .notes, .codebook])
    }

    /// Auto has no tab: its cards sit in the rail beside the transcript. Its
    /// old ⌘3 slot stays, so no later digit shifts, and opens Transcript.
    func testAutoHasNoTabAndItsKeptSlotOpensTranscript() {
        XCTAssertFalse(OverlayTab.allCases.map(\.rawValue).contains("auto"))
        XCTAssertNil(OverlayTab(rawValue: "auto"))
        XCTAssertEqual(OverlayTab(rawValue: OverlayTabShortcut.destination(forTab: OverlayTabShortcut.liveHelpSlot)), .transcript)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: OverlayTabShortcut.liveHelpSlot), 3)
        XCTAssertEqual(OverlayTab.allCases.map(\.shortcutNumber), [1, 2, 4, 5, 6, 7])
        XCTAssertEqual(OverlayTab.transcript.shortcutLabel, "⌘4")
    }

    func testGuidedResearchKeepsIndependentNotesTabAndShortcuts() {
        XCTAssertEqual(OverlayTab.visibleTabs(notes: true, guide: true), [.assist, .transcript, .guide, .notes])
        XCTAssertEqual(OverlayTab.visibleTabs(notes: false, guide: true), [.assist, .transcript, .guide])
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "guide", guideActive: true), 5)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "notes", guideActive: true), 6)
        XCTAssertEqual(OverlayTabShortcut.number(forTab: "notes"), 5)
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

    /// NET-5: a provider outage long enough to trip the backlog cap. The
    /// recovered pass notes only the newest part; the part before it must be
    /// marked in the notes (and so in notes.md and the sidecar), never left
    /// as a silent hole.
    func testBacklogCapAfterAnOutageMarksTheSkippedStretch() async {
        let startedAt = Date().addingTimeInterval(-600)
        let entries = (0..<100).map { index in
            LiveEntry(speakerId: index % 2 == 0 ? "self" : "remote_1",
                      text: "Invented fixture sentence number \(index) about the sample brief, padded to length " + String(repeating: "x", count: 40),
                      startMs: index * 6_000, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        }
        MeetingContextStore.shared.resetAfterSession()
        SessionCoordinator.shared.seedForRenderProof(entries: entries, interim: nil, phase: .idle, startedAt: startedAt)
        defer { clearGenerationTranscript() }
        let gate = GenerationResponseGate()
        let controller = NotesGenerationController(request: generationRequest(gate))
        controller.reset(for: "outage")

        async let failed = controller.generate(sessionId: "outage")
        await gate.waitForCalls(1)
        await gate.finish(0, text: "")
        _ = await failed
        XCTAssertEqual(controller.lastError, "Couldn't generate notes just now. RTI tries again on the next pass.")
        XCTAssertTrue(controller.notes.isEmpty)

        async let recovered = controller.generate(sessionId: "outage")
        await gate.waitForCalls(2)
        await gate.finish(1, text: "TITLE: Recovered\n- Newest part")
        _ = await recovered
        XCTAssertEqual(controller.notes.map(\.title), [NotesGenerationController.skippedTitle, "Recovered"])
        let marker = controller.notes[0]
        let note = controller.notes[1]
        XCTAssertEqual(marker.rangeStartMs, 0)
        XCTAssertGreaterThan(note.rangeStartMs, 0, "the cap did drop the older part")
        XCTAssertEqual(marker.rangeEndMs, note.rangeStartMs, "the marker covers exactly what the cap dropped")
        XCTAssertTrue(marker.content.contains("transcript and the audio keep every word"))
    }

    /// NET-5: the talk after the last tick gets one bounded final pass.
    func testFinishWritesTheLastIntervalAndIsBounded() async {
        let key = NotesSettings.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)
        let early = LiveEntry(speakerId: "self", text: "Invented opening point", startMs: 1_000,
                              confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        let late = LiveEntry(speakerId: "remote_1", text: "Invented point made after the last tick", startMs: 90_000,
                             confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        MeetingContextStore.shared.resetAfterSession()
        SessionCoordinator.shared.seedForRenderProof(entries: [early], interim: nil, phase: .idle, startedAt: nil)
        defer { clearGenerationTranscript() }
        let gate = GenerationResponseGate()
        let controller = NotesGenerationController(request: generationRequest(gate))
        controller.reset(for: "final")
        async let tick = controller.generate(sessionId: "final")
        await gate.waitForCalls(1)
        await gate.finish(0, text: "TITLE: Opening\n- Opening point")
        _ = await tick

        SessionCoordinator.shared.seedForRenderProof(entries: [early, late], interim: nil, phase: .idle, startedAt: nil)
        async let finished: Void = controller.finish(sessionId: "final")
        await gate.waitForCalls(2)
        await gate.finish(1, text: "TITLE: Closing\n- Late point")
        await finished
        XCTAssertEqual(controller.notes.map(\.title), ["Opening", "Closing"])
        XCTAssertEqual(controller.notes.last?.rangeEndMs, 90_000, "the final block reaches the last words")

        // A provider that never answers cannot hold Stop past the limit.
        SessionCoordinator.shared.seedForRenderProof(
            entries: [early, late, LiveEntry(speakerId: "self", text: "Invented closing words", startMs: 120_000, confidence: 1,
                                             translationStatus: "none", language: nil, sourceLanguage: nil)],
            interim: nil, phase: .idle, startedAt: nil)
        let clock = ContinuousClock.now
        await controller.finish(sessionId: "final", timeout: 0.2)
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(2))
        await gate.waitForCalls(3)
        await gate.finish(2, text: "")
    }

    /// F2 (batch 6): a manual "Write notes now" pass was running when Stop
    /// came. The Stop pass does not wait for it, so the archive and the
    /// sidecar were written without its block, and the block was on screen
    /// only until the next Record cleared it. The refresher now writes it to
    /// notes.md and the sidecar when it lands; a failed write is shown.
    func testNotesBlockThatLandsAfterTheArchiveReachesNotesMdAndTheSidecar() async throws {
        let enabled = NotesSettings.enabledKey
        let savedEnabled = UserDefaults.standard.object(forKey: enabled)
        let savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-late-notes-\(UUID().uuidString)", isDirectory: true)
        defer {
            if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: enabled) } else { UserDefaults.standard.removeObject(forKey: enabled) }
            if let savedConfigHome { setenv("RTI_CONFIG_HOME", savedConfigHome, 1) } else { unsetenv("RTI_CONFIG_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set(true, forKey: enabled)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ]).write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)

        seedGenerationTranscript()
        defer { clearGenerationTranscript() }
        let sessionID = "invented-late-notes"
        let gate = GenerationResponseGate()
        let controller = NotesGenerationController(request: generationRequest(gate))
        controller.reset(for: sessionID)
        var failures: [String] = []
        let refresher = LateChatArchiveRefresher(store: { nil }, reportFailure: { failures.append($0) })

        // The user pressed "Write notes now"; the provider is still busy at Stop.
        async let manual = controller.generate(sessionId: sessionID)
        await gate.waitForCalls(1)
        refresher.begin(sessionID: sessionID)
        await controller.finish(sessionId: sessionID)
        XCTAssertTrue(controller.notes.isEmpty, "precondition: the Stop pass did not wait for the manual one")

        // completeStop: archive and sidecar from the notes as they are now.
        let startedAt = Date(timeIntervalSince1970: 1_782_000_000)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(300),
            transcript: [LiveEntry(speakerId: "self", text: "Invented archived words", startMs: 1000, confidence: 1,
                                   translationStatus: "none", language: nil, sourceLanguage: nil)],
            chat: [], visualContext: [], notes: controller.notes,
            sessionId: sessionID, micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        let sidecar = try XCTUnwrap(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: directory, callType: .client))
        refresher.archived(sessionID: sessionID, snapshot: snapshot, archiveDir: directory, callType: .client)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.md").path))

        // The manual pass lands after the archive.
        await gate.finish(0, text: "TITLE: LATE BLOCK\n- Invented late point")
        _ = await manual
        XCTAssertEqual(controller.notes.map(\.title), ["LATE BLOCK"])
        let notesFile = directory.appendingPathComponent("notes.md")
        for _ in 0 ..< 500 where !FileManager.default.fileExists(atPath: notesFile.path) {
            await refresher.settled()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await refresher.settled()
        XCTAssertTrue(try String(contentsOf: notesFile, encoding: .utf8).contains("Invented late point"))
        let sidecarText = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(sidecarText.contains("## Generated notes"), sidecarText)
        XCTAssertTrue(sidecarText.contains("Invented late point"), sidecarText)
        XCTAssertTrue(failures.isEmpty)

        // Another recording's block leaves this one alone.
        refresher.notesAdded(sessionID: "some-other-session", notes: [])
        XCTAssertEqual(refresher.target?.snapshot?.notes.map(\.title), ["LATE BLOCK"])

        // A block that cannot be written is shown, not only logged.
        try FileManager.default.removeItem(at: notesFile)
        try FileManager.default.createDirectory(at: notesFile, withIntermediateDirectories: true)
        refresher.notesAdded(sessionID: sessionID, notes: controller.notes + [
            GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 1, title: "Second late", content: "- Invented second point"),
        ])
        await refresher.settled()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.contains("Copy it from the Notes tab") == true)
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
