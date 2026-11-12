import Foundation
import RTICore
import XCTest

final class SessionMarkersTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rti-marker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testAppendFlushReopenTornTailAndSameIDRetry() throws {
        let directory = try temporaryDirectory()
        let one = SessionNote(id: "first", kind: .marker, offsetMs: 2750, text: "/Tile B\n第二行")
        let two = SessionNote(id: "second", kind: .note, offsetMs: 4800, text: "先听一会。")
        try SessionMarkerJournal.append(one, in: directory)
        let path = directory.appendingPathComponent("notes.jsonl")
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{partial".utf8))
        try handle.close()

        XCTAssertEqual(try SessionMarkerJournal.read(in: directory), [one])
        try SessionMarkerJournal.append(two, in: directory)
        try SessionMarkerJournal.append(two, in: directory)
        XCTAssertEqual(try SessionMarkerJournal.read(in: directory), [one, two])
        var conflict = two
        conflict.text = "different words"
        XCTAssertThrowsError(try SessionMarkerJournal.append(conflict, in: directory))
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        let pipeline = TranscriptPipeline()
        pipeline.replaceNotes([one])
        pipeline.prepareForReconnect()
        XCTAssertEqual(pipeline.liveEntries.first?.startMs, 2750)
        pipeline.replaceNotes([one, two])
        XCTAssertEqual(pipeline.liveEntries.map(\.text), ["/Tile B\n第二行", "先听一会。"])
    }

    func testKnownEmptyRevisitCorrectionAndIndependentQuestions() {
        let a = SessionNote(id: "q", kind: .marker, offsetMs: 1000, text: "/S1Q2", guideQuestionID: "S1Q2")
        let b = SessionNote(id: "b", kind: .stimulus, offsetMs: 2000, text: "A1 + B1", shownCodes: ["A1", "B1"], packageRevision: "v1")
        let clear = SessionNote(id: "c", kind: .stimulus, offsetMs: 3000, shownCodes: [], packageRevision: "v1")
        let reveal = SessionNote(id: "r", kind: .stimulus, offsetMs: 4000, shownCodes: ["R1"], revealed: true, packageRevision: "v1")
        let revisit = SessionNote(id: "back", kind: .stimulus, offsetMs: 5000, shownCodes: ["A1"], packageRevision: "v1")
        let fix = SessionNote(id: "fix", kind: .correction, offsetMs: 6000, replaces: "b",
                              replacement: .init(text: "B1", shownCodes: ["B1"], offsetMs: 1800))
        let timeline = MarkerTimeline(events: [a, b, clear, reveal, revisit, fix, fix])
        XCTAssertNil(timeline.context(at: 500).shownCodes)
        XCTAssertEqual(timeline.context(at: 1800).shownCodes, ["B1"])
        XCTAssertEqual(timeline.context(at: 3000).shownCodes, [])
        XCTAssertEqual(timeline.context(at: 5001).guideQuestionID, "S1Q2")
        XCTAssertTrue(timeline.context(at: 5001).revealRecorded)
        XCTAssertEqual(timeline.context(at: 5001).showEventID, "back")
        XCTAssertEqual(timeline.spans(through: 7000).map(\.endMs), [1800, 3000, 4000, 5000, 7000])
    }

    func testUpgradePreservesLiveEvidenceAcrossBoundaryAndConsecutiveRuns() async throws {
        let directory = try temporaryDirectory()
        let a = SessionNote(id: "first", kind: .marker, offsetMs: 1000, text: "/Shape A\n第一张")
        let b = SessionNote(id: "second", kind: .marker, offsetMs: 4000, text: "/Shape B")
        let last = SessionNote(id: "silence", kind: .note, offsetMs: 25000, text: "check later")
        for event in [a, b, last] {
            try SessionMarkerJournal.append(event, in: directory)
        }
        let source = SessionAnnotatedTurn(turnID: "remote_1@3990", rawSpeaker: "remote_1", leg: "Them",
                                          speakerConfidence: "unverified", original: "蓝色。", liveStartMs: 3990, endMs: 4000,
                                          context: MarkerTimeline(events: [a, b]).context(at: 3990))
        let evidence = SessionEvidence(sessionID: "fixture", groupID: "G1", events: [a, b, last], through: 30000, turns: [source])
        try evidence.write(in: directory)
        try "# Transcript".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        // The discovery code accepts a legacy non-RIFF payload. The provider is a fixture closure.
        try Data(repeating: 1, count: 160).write(to: directory.appendingPathComponent("audio-system.wav"))
        for _ in 0 ..< 2 {
            _ = try await TranscriptUpgradePipeline.upgrade(sessionDir: directory, startedAt: Date(), providerID: "fixture",
                                                            providerDisplayName: "Fixture", frontmatter: [], progress: { _ in },
                                                            transcribe: { _, _ in "[00:04.020] Speaker 1: 蓝色。" })
            let after = try XCTUnwrap(try SessionEvidence.read(in: directory))
            XCTAssertEqual(after.notes, [a, b, last])
            XCTAssertEqual(after.turns.first?.original, "蓝色。")
            XCTAssertEqual(after.turns.first?.context.markerID, "first")
            XCTAssertEqual(after.turns.first?.upgradedStartMs, 4020)
            XCTAssertEqual(after.turns.first?.anchor, "review boundary")
            XCTAssertEqual(after.upgradedTurns?.first?.liveTurnIDs, [source.turnID])
            XCTAssertEqual(after.upgradedTurns?.first?.context?.markerID, "first")
            XCTAssertEqual(after.noteAnchors.last?.approximate, true)
            let text = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
            let raw = SessionEvidence.raw(from: text)
            XCTAssertTrue(raw.contains("第一张"))
            XCTAssertTrue(raw.contains("review boundary"))
            XCTAssertTrue(raw.contains("Remote speaker 1: 蓝色。"))
        }
    }

    func testPackageSHAIncludesSourceAndRetainsMissingItemAsManualReference() throws {
        let dir = try temporaryDirectory()
        let slides = dir.appendingPathComponent("slides")
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        let manifest = dir.appendingPathComponent("stim-manifest.json")
        let source = slides.appendingPathComponent("one.html")
        try "shape one".write(to: source, atomically: true, encoding: .utf8)
        let json = """
        {"source":"slides","version":"v1","slides":[{"id":"one","code":"A1","moment":"T","product":"private mapping"},
          {"id":"missing","code":"B1","moment":"T"}]}
        """
        try json.write(to: manifest, atomically: true, encoding: .utf8)
        let first = try StimulusPackage.read(manifest: manifest)
        XCTAssertEqual(first.items.map(\.sourceAvailable), [true, false])
        XCTAssertEqual(first.items.map(\.code), ["A1", "B1"])
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(first), as: UTF8.self).contains("private mapping"))
        try "shape two".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try StimulusPackage.read(manifest: manifest).revision, first.revision)
    }

    func testNotesWithoutSpeechSurviveAudioUpgradeAndProduceRawExport() async throws {
        let directory = try temporaryDirectory()
        let note = SessionNote(kind: .marker, offsetMs: 1500, text: "/无对白", sessionID: "silent-fixture")
        try SessionMarkerJournal.append(note, in: directory)
        try "# Recovered".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 160).write(to: directory.appendingPathComponent("audio-mic.wav"))
        _ = try await TranscriptUpgradePipeline.upgrade(sessionDir: directory, startedAt: Date(), providerID: "fixture",
                                                        providerDisplayName: "Fixture", frontmatter: [], progress: { _ in },
                                                        transcribe: { _, _ in "" })
        let after = try XCTUnwrap(try SessionEvidence.read(in: directory))
        XCTAssertEqual(after.notes, [note])
        XCTAssertEqual(after.noteAnchors.first?.approximate, true)
        let text = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(SessionEvidence.raw(from: text).contains("无对白"))
    }

    func testRawExportRetainsMultilineSpeechBetweenAnnotationRecords() {
        let md = """
        # Transcript
        `00:00:02` **📝 Note:** RTI context · Section: Shape A
        `00:00:02.500` **Them:** The first line.
        第二行。

        `00:00:03` **📝 Note:** Material · Boards down
        """
        let output = SessionEvidence.raw(from: md)
        XCTAssertTrue(output.contains("Them: The first line.\n第二行。"))
        XCTAssertTrue(output.contains("# Material · Boards down"))
    }

    func testLegacyArchiveAndReadFailureAreDistinct() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(try SessionMarkerJournal.read(in: directory), [])
        XCTAssertNil(try SessionEvidence.read(in: directory))
        try Data("bad\n".utf8).write(to: directory.appendingPathComponent("notes.jsonl"))
        XCTAssertThrowsError(try SessionMarkerJournal.read(in: directory))
    }
}
