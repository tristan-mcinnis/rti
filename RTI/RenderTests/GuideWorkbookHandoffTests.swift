import RTICore
import XCTest

@MainActor
final class GuideWorkbookHandoffTests: RenderProofTestCase {
    /// Exercise the real provider adapter, final tail, archive and sidecar together.
    /// The fixture vault also supplies a complete archive for the external workbook checker.
    func testScheduledPassAndFinalTailProduceAnImportableGroup() async throws {
        // Keep this persistent proof outside the shared six-session UI fixture.
        let root = RenderProofHarness.outputDirectory.appendingPathComponent("guide-handoff-\(ProcessInfo.processInfo.processIdentifier)")
        let config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let paths = ["sessions_dir": root.appendingPathComponent("sessions").path,
                     "recordings_dir": root.appendingPathComponent("meetings/recordings").path]
        try JSONEncoder().encode(paths).write(to: config.appendingPathComponent("config.json"))
        let previous = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        setenv("RTI_CONFIG_HOME", config.path, 1)
        defer {
            if let previous {
                setenv("RTI_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("RTI_CONFIG_HOME")
            }
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/GuideFixtures")
        let guideURL = fixture.appendingPathComponent("dg-questions.json")
        let rosterURL = fixture.appendingPathComponent("roster.csv")
        let guide = try GuideDocument.parse(Data(contentsOf: guideURL))
        let roster = try GuideRoster.parse(Data(contentsOf: rosterURL), fileExtension: "csv")
        let entries = [
            RenderFixtures.liveEntry("self", "Which cup would you choose?", 1000),
            RenderFixtures.liveEntry("remote_1", "我选 A。", 4000),
            RenderFixtures.liveEntry("self", "How would you carry it?", 9000),
            RenderFixtures.liveEntry("remote_2", "In the side pocket.", 12000),
        ]
        let turns = GuideSessionController.sourceTurns(from: entries)
        let choice = try XCTUnwrap(turns.first { $0.speaker == "remote_1" }).id
        let carrying = try XCTUnwrap(turns.first { $0.speaker == "remote_2" }).id
        let moderator = try XCTUnwrap(turns.first { $0.speaker == "self" }).id
        let reply = """
        {"evidence":[],"cells":[
          {"qid":"S1Q1","coverage":"Answered","summary":"One respondent chose A.","turns":["\(choice)"],
           "quotes":[{"turn":"\(moderator)","english":"Which cup?"},{"turn":"\(choice)","english":"I choose A."}],
           "votes":[{"turn":"\(choice)","choice":"A"}]},
          {"qid":"S1Q2","coverage":"Answered","summary":"One respondent uses the side pocket.","turns":["\(carrying)"],
           "quotes":[{"turn":"\(carrying)","english":"(English original)"}],"votes":[]}]}
        """
        let request = LLMRequest(collectStream: { _, _, _, _ in
            LLMClient.CollectedResponse(text: reply, finishReason: "stop", reasoningCharacters: 0)
        }, priority: .background, admission: LLMAdmissionController())
        let session = "mock-cup-workbook"
        let controller = GuideSessionController(request: request)
        controller.start(sessionID: session, guide: guide, guideURL: guideURL, group: "G1", roster: roster, rosterURL: rosterURL)
        let names = SpeakerNameStore.shared
        names.reset()
        defer { names.reset() }
        names.assign(GuideSpeakerAssignment(seat: roster[0]), to: "remote_1")
        names.assign(GuideSpeakerAssignment(seat: roster[1]), to: "remote_2")

        let firstPass = await controller.generate(sessionId: session, entries: entries)
        XCTAssertNotNil(firstPass)
        XCTAssertEqual(controller.extraction?.cells[0].quotes.map(\.original), ["我选 A。"])
        await controller.finish(sessionId: session, entries: entries)
        let snapshot = try XCTUnwrap(controller.snapshot(for: session))
        XCTAssertFalse(snapshot.extraction.captureIncomplete)
        let start = Date(timeIntervalSince1970: 1_715_300_000)
        let recording = SessionFinalizer.Snapshot(
            startedAt: start, endedAt: start.addingTimeInterval(15), transcript: entries, chat: [],
            visualContext: [], notes: [], sessionId: session, micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: "Research", guide: snapshot
        )
        let archive = try XCTUnwrap(SessionFinalizer(snapshot: recording).archive())
        let sidecar = try XCTUnwrap(SessionArchive.writeCanonicalMeetingSidecar(
            startedAt: start, chat: [], visualContext: [], notes: [], archiveDir: archive, callType: .research
        ))
        let written = try JSONDecoder().decode(GuideExtraction.self, from: Data(contentsOf: archive.appendingPathComponent("guide-cells-G1.json")))
        XCTAssertEqual(written.cells.map(\.coverage), ["Answered", "Answered", "Not covered"])
        XCTAssertEqual(written.cells[0].quotes.map(\.participant), ["P1"])
        XCTAssertEqual(written.cells[0].tally, "1 of 3 chose A")
        XCTAssertEqual(written.cells[1].quotes.map(\.original), ["In the side pocket."])
        XCTAssertEqual(written.cells[1].quotes.first?.locator, "00:00:12")
        let frontmatter = try String(contentsOf: sidecar, encoding: .utf8)
        for expected in [archive.path, guideURL.path, rosterURL.path, "group_id:"] {
            XCTAssertTrue(frontmatter.contains(expected))
        }

        // Simulate the batch provider re-diarizing the first respondent and
        // correcting the second answer. Both originals must survive the handoff.
        try Data("synthetic leg".utf8).write(to: archive.appendingPathComponent("audio-system.m4a"))
        let upgrade = try await TranscriptUpgradePipeline.upgrade(
            sessionDir: archive, startedAt: start, providerID: "fixture", providerDisplayName: "Fixture",
            frontmatter: [], progress: { _ in }, transcribe: { _, _ in
                "[00:05] Speaker 4: 我选 A。\n[00:13] Speaker 7: In the front pocket."
            }
        )
        try SessionArchive.reanchorGuide(in: archive, upgradedTurns: upgrade.guideAnchorTurns)
        let anchored = try JSONDecoder().decode(GuideExtraction.self, from: Data(contentsOf: archive.appendingPathComponent("guide-cells-G1.json")))
        XCTAssertEqual(anchored.cells[0].quotes.first?.verification, "verified")
        XCTAssertEqual(anchored.cells[0].quotes.first?.locator, "00:00:05")
        XCTAssertEqual(anchored.cells[1].quotes.first?.verification, "unverified")
        XCTAssertEqual(anchored.cells[1].quotes.first?.original, "In the side pocket.")

        // The upgrade moves the exact first quote from 4 s to 5 s, across
        // a guide marker at 4.5 s. The second quote keeps its live anchor.
        _ = try SessionMarkerJournal.append(SessionNote(kind: .marker, offsetMs: 4500, text: "/S1Q2", guideQuestionID: "S1Q2"), in: archive)
        _ = try SessionMarkerJournal.append(SessionNote(kind: .marker, offsetMs: 9000, text: "/S2Q1", guideQuestionID: "S2Q1"), in: archive)
        try SessionArchive.reanchorGuide(in: archive, upgradedTurns: upgrade.guideAnchorTurns)
        let refiled = try JSONDecoder().decode(GuideExtraction.self, from: Data(contentsOf: archive.appendingPathComponent("guide-cells-G1.json")))
        XCTAssertTrue(refiled.cells[0].orderedQuotes.isEmpty)
        XCTAssertEqual(refiled.cells[1].orderedQuotes.map(\.original), ["我选 A。"])
        XCTAssertEqual(refiled.cells.last?.orderedQuotes.map(\.original), ["In the side pocket."])
    }
}
