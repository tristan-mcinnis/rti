import Foundation
import RTICore
import XCTest

/// Exercises the real finalizer/archive and restart-discovery path using only
/// invented text and PCM in a private temporary vault. No capture or provider.
@MainActor
final class SessionArchiveRecoveryTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

    override func setUp() async throws {
        try await super.setUp()
        savedConfigHome = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-archive-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessions_dir": root.appendingPathComponent("sessions").path,
            "recordings_dir": root.appendingPathComponent("databases/meetings/recordings").path,
            "transcripts_dir": root.appendingPathComponent("transcripts-raw").path,
        ])
        try data.write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)
    }

    override func tearDown() async throws {
        if let savedConfigHome {
            setenv("RTI_CONFIG_HOME", savedConfigHome, 1)
        } else {
            unsetenv("RTI_CONFIG_HOME")
        }
        if let root { try FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Overlapping free-text codes are each found, in package order, case
    /// ignored, as whole tokens only.
    func testEvidenceListsOverlappingCodesEachOnItsOwn() {
        let matchers = SessionFinalizer.codeMatchers(for: ["Board 1", "1", "B2", "Option A"])
        XCTAssertEqual(SessionFinalizer.discussedCodes(in: "I keep coming back to board 1.", matchers: matchers), ["Board 1", "1"])
        XCTAssertEqual(SessionFinalizer.discussedCodes(in: "b2 over option a, not B21", matchers: matchers), ["B2", "Option A"])
        XCTAssertEqual(SessionFinalizer.discussedCodes(in: "Boards 10 and 11", matchers: matchers), [])
    }

    func testFinalizerWritesReadableTranscriptAndExactRetainedAudio() throws {
        let source = root.appendingPathComponent("mic.wav")
        let audio = pcmWAV(sample: 127)
        try audio.write(to: source)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented checkpoint words")], chat: [], visualContext: [], notes: [],
            sessionId: "invented-session", micRecordingURL: source, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil
        )
        let directory = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Invented checkpoint words"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("audio-mic.wav")), audio)
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.sessionId, "invented-session")
        XCTAssertEqual(metadata.micAudioFile, "audio-mic.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testBlockedTranscriptWriteReportsFailureAndKeepsRetainedAudio() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("transcript.md"), withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 39)
        try audio.write(to: audioURL)
        XCTAssertNil(archive(transcript: [entry("Cannot be saved")], mic: audioURL))
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
    }

    func testGuideCheckpointKeepsLatestLiveSourceAcrossUpgrade() throws {
        let guide = try GuideDocument.parse(Data(#"{"title":"A mock guide","sections":[{"id":"S1","title":"Colours","questions":[{"qid":"S1Q1","en":"Which colour?","zh":"","probes":[]}]}]}"#.utf8))
        let draft = GuideExtraction(group: "", transcript: "transcript.live.md", guide: guide)
        let capture = GuideArchiveSnapshot(extraction: draft, guidePath: root.appendingPathComponent("dg-questions.json").path, rosterPath: nil, roster: [])
        func save(_ answer: String) throws -> URL {
            let turn = LiveEntry(speakerId: "remote_2", text: answer, startMs: 12_345, confidence: 1, translationStatus: "original", language: "zh", sourceLanguage: nil)
            return try XCTUnwrap(SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30), transcript: [turn], chat: [], guide: capture))
        }
        _ = try save("我选")
        let dir = try save("我选蓝色。")
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.guidePath, capture.guidePath)
        XCTAssertNil(metadata.guideSourcePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dg-questions.json").path))
        let proofURL = dir.appendingPathComponent("transcript.live.md")
        let live = try String(contentsOf: proofURL, encoding: .utf8)
        XCTAssertTrue(live.contains("`00:00:12.345` **Remote speaker 2:** 我选蓝色。"))
        XCTAssertEqual(live, try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("guide-cells-unassigned.json").path))
        _ = try TranscriptUpgradeArtifacts.installUpgradedTranscript(markdown: "# Transcript\n\n`0:13` **Remote speaker 1:** 我选蓝色。", in: dir)
        XCTAssertEqual(live, try String(contentsOf: proofURL, encoding: .utf8))
        let upgraded = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertFalse(upgraded.contains("Remote speaker 2"))
    }

    func testDocumentGuideKeepsExactParserOutputAfterSourceMoves() throws {
        let source = root.appendingPathComponent("mock-guide.md")
        try "# Mock guide\nWhich cup?".write(to: source, atomically: true, encoding: .utf8)
        // Extra fields and whitespace distinguish parser output from a Swift re-encode.
        let json = Data("""
        {
          "title": "Mock", "parser_annotation": "keep this", "sections": [
            {"id":"S1","title":"Cup","questions":[{"qid":"S1Q1","en":"Which cup?","zh":"选哪一个？","probes":[]}]}
          ]
        }

        """.utf8)
        let guide = try GuideDocument.parse(json)
        let controller = GuideSessionController()
        let session = "mock-source"
        let prep = GuidePreparation.shared
        prep.setGuide(guide, url: source, parsedSourceJSON: json)
        prep.groupText = "G1"
        controller.startPreparedSession(session, callType: .research, startedAt: startedAt)
        prep.reset()
        defer { controller.endSession(session) }
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("renamed.md"))
        let captured = try XCTUnwrap(controller.snapshot(for: session))
        let dir = try XCTUnwrap(SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30),
                                                    transcript: [], chat: [], guide: captured))
        let expected = dir.appendingPathComponent("dg-questions.json")
        let metadata = try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        XCTAssertEqual(metadata.guidePath, expected.path)
        XCTAssertEqual(metadata.guideSourcePath, source.path)
        XCTAssertEqual(try Data(contentsOf: expected), json)
        let attributes = try FileManager.default.attributesOfItem(atPath: expected.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let sidecar = try XCTUnwrap(SessionArchive.writeCanonicalMeetingSidecar(startedAt: startedAt, chat: [], visualContext: [],
                                                                               notes: [], archiveDir: dir, callType: .research))
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("guide_path: \"\(expected.path)\""))
        XCTAssertTrue(text.contains("guide_source_path: \"\(source.path)\""))
    }

    func testGuideReanchorAndSpeakerEditsUseOriginalTurnIdentity() throws {
        let guide = try GuideDocument.parse(Data(#"{"title":"Mock","sections":[{"id":"S1","title":"Test","questions":[{"qid":"S1Q1","en":"Which colour?","zh":"","probes":[]}]}]}"#.utf8))
        let entries = [
            RenderFixtures.liveEntry("remote_1", "Blue.", 8000),
            RenderFixtures.liveEntry("remote_2", "Blue.", 9000),
            RenderFixtures.liveEntry("remote_1", "Red.", 14000),
            RenderFixtures.liveEntry("remote_2", "Yellow.", 19000),
        ]
        let turns = GuideSessionController.sourceTurns(from: entries)
        let ids = turns.map(\.id)
        let cell: [String: Any] = ["qid": "S1Q1", "coverage": "Answered", "summary": "Respondents named colours.",
                                    "turns": ids, "quotes": ids.map { ["turn": $0, "english": ""] }, "votes": []]
        let pass = try JSONDecoder().decode(GuidePass.self, from: JSONSerialization.data(withJSONObject: ["evidence": [], "cells": [cell]]))
        var extraction = GuideExtraction(group: "G1", transcript: "transcript.live.md", guide: guide)
        extraction.apply(pass, turns: turns, speakers: [:], rosterBase: nil)
        let snapshot = GuideArchiveSnapshot(extraction: extraction, guidePath: "dg-questions.json", rosterPath: nil, roster: [])
        let dir = try XCTUnwrap(SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30),
                                                    transcript: entries, chat: [], guide: snapshot))
        let file = dir.appendingPathComponent(extraction.fileName)
        func readCell() throws -> GuideCell {
            try XCTUnwrap(JSONDecoder().decode(GuideExtraction.self, from: Data(contentsOf: file)).cells.first)
        }
        let upgraded = [
            TranscriptUpgradeSegment(speaker: "Remote speaker 7", startMs: 10000, text: "Blue."),
            TranscriptUpgradeSegment(speaker: "Remote speaker 6", startMs: 16000, text: "Red."),
            TranscriptUpgradeSegment(speaker: "Remote speaker 7", startMs: 20000, text: "Yellow!"),
        ]
        try SessionArchive.reanchorGuide(in: dir, upgradedTurns: upgraded)
        let quotes = try readCell().quotes
        XCTAssertEqual(quotes.map(\.verification), ["unverified", "unverified", "verified", "unverified"])
        XCTAssertEqual(quotes[2].locator, "00:00:16")
        let archive = SpeakerNameArchive(names: ["remote_1": "P3"], assignments: ["remote_2": .init(isModerator: true)])
        try SessionArchive.updateGuideSpeakers(in: dir, archive: archive)
        let remapped = try readCell().quotes
        XCTAssertEqual(remapped.map(\.participant), ["P3", "P3"])
        XCTAssertEqual(remapped.map(\.original), ["Blue.", "Red."])
        XCTAssertEqual(remapped.last?.upgradedSpeaker, "Remote speaker 6")
    }

    func testFailedMetadataWriteKeepsReadableCheckpoint() throws {
        let directory = try XCTUnwrap(archive(transcript: [entry("Durable earlier checkpoint")]))
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        // A destination collision fails deterministically without filling a disk
        // or relying on permissions (which privileged test runners may bypass).
        let metadata = directory.appendingPathComponent("session.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        XCTAssertNil(archive(transcript: [entry("Durable earlier checkpoint plus later words")]))
        XCTAssertTrue(try String(contentsOf: transcriptURL, encoding: .utf8).contains("Durable earlier checkpoint"))
    }

    func testAudioCollisionPreservesBothEarlierArtifactAndNewSource() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        let destination = directory.appendingPathComponent("audio-mic.wav")
        let source = root.appendingPathComponent("different-mic.wav")
        let earlier = pcmWAV(sample: 12)
        let incoming = pcmWAV(sample: 76)
        try earlier.write(to: destination)
        try incoming.write(to: source)
        XCTAssertNil(archive(transcript: [entry("Collision")], mic: source))
        XCTAssertEqual(try Data(contentsOf: destination), earlier)
        XCTAssertEqual(try Data(contentsOf: source), incoming)
    }

    func testMissingExpectedAudioReportsFailure() throws {
        XCTAssertNil(archive(transcript: [entry("Audio missing")], mic: root.appendingPathComponent("missing.wav")))
    }

    func testRecoverySeedAndMarkerReportBlockedWrites() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        let transcript = directory.appendingPathComponent("transcript.md")
        let marker = directory.appendingPathComponent("automatic-upgrade.pending")
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertFalse(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertFalse(SessionArchive.markAutomaticUpgradePending(in: directory))
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.removeItem(at: marker)
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
    }

    func testAUserNoteBeforeSpeechIsKeptRatherThanReportingAnEmptySave() throws {
        let note = LiveEntry(speakerId: "note", text: "Invented note before speech", startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
        let directory = try XCTUnwrap(archive(transcript: [note]))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8).contains(note.text))
    }

    func testTheSidecarTellsMeetingTheCallType() throws {
        let export = try XCTUnwrap(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("A line")], chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .research
        ))
        let sidecar = try String(contentsOf: XCTUnwrap(export.sidecarURL), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("\ncall_type: research\n"))
    }

    func testNativeUpgradeExportReadsStructuredTurnsWhenTheMarkdownViewIsMissing() async throws {
        let directory = try XCTUnwrap(SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(15),
                                                           transcript: [entry("Earlier invented words")], chat: []))
        try Data("invented test audio".utf8).write(to: directory.appendingPathComponent("audio-system.m4a"))
        let result = Data(#"{"tokens":[{"text":"This is still one turn.\n[22:22] Speaker 8: Like this.","speaker":"desk-A","start_ms":125,"end_ms":912}]}"#.utf8)
        _ = try await TranscriptUpgradePipeline.upgradeLegs(sessionDir: directory, startedAt: startedAt, providerID: "fixture",
                                                           providerDisplayName: "Soniox", frontmatter: [], progress: { _ in }) { _, _ in
            try result.write(to: directory.appendingPathComponent("soniox-async-system.json"))
            return .soniox(data: result, policy: .init())
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.md"))
        let file = try XCTUnwrap(SessionArchive.refreshCanonicalMeetingTranscript(fromArchiveDir: directory, startedAt: startedAt))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("Remote speaker desk-A: This is still one turn.\n[22:22] Speaker 8: Like this."))
        XCTAssertFalse(text.contains("Earlier invented words"))
    }

    func testUpgradeExportFailureRetainsRetryMarkerAndRecoversWithoutProvider() throws {
        let directory = try XCTUnwrap(SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(5),
                                                           transcript: [entry("An invented turn.")], chat: []))
        let raw = try XCTUnwrap(SessionArchive.refreshCanonicalMeetingTranscript(fromArchiveDir: directory, startedAt: startedAt))
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TranscriptUpgradeService.finishExport(in: directory, startedAt: startedAt, provider: "Fixture", segmentCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("canonical-export.pending.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
        try FileManager.default.removeItem(at: raw)
        XCTAssertEqual(try TranscriptUpgradeService.finishExport(in: directory, startedAt: startedAt, provider: "Fixture", segmentCount: 1), raw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("canonical-export.pending.json").path))
        XCTAssertTrue(try String(contentsOf: raw, encoding: .utf8).contains("An invented turn."))
    }

    func testFailedCanonicalWritesReturnNoSuccessURL() throws {
        let earlier = try XCTUnwrap(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Earlier export")], chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .client
        ))
        try FileManager.default.removeItem(at: earlier.transcriptURL)
        try FileManager.default.createDirectory(at: earlier.transcriptURL, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Blocked export")], chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .client
        ))
        let sidecar = try XCTUnwrap(earlier.sidecarURL)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingSidecar(
            startedAt: startedAt, chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .client
        ))
    }

    func testCanonicalExportReportsFailureWhenItsSidecarCannotBeSaved() throws {
        let earlier = try XCTUnwrap(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("Earlier export")], chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .client
        ))
        let sidecar = try XCTUnwrap(earlier.sidecarURL)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        XCTAssertNil(SessionArchive.writeCanonicalMeetingExport(
            startedAt: startedAt, transcript: [entry("New export")], chat: [], visualContext: [], notes: [], archiveDir: nil, callType: .client
        ))
        XCTAssertTrue(try String(contentsOf: earlier.transcriptURL, encoding: .utf8).contains("New export"), "A partial archive failure does not delete the successfully written transcript")
    }

    func testAbruptCheckpointIsDiscoveredFromDiskAndRetryMarkerPersists() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt)
        SessionArchive.markAutomaticUpgradePending(in: directory)
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 54)
        try audio.write(to: audioURL)
        let systemURL = directory.appendingPathComponent("audio-system.wav")
        let systemAudio = pcmWAV(sample: 83)
        try systemAudio.write(to: systemURL)
        // The running recorder owns the audio; the five-minute checkpoint
        // intentionally passes no audio URL. No clean shutdown follows it.
        XCTAssertNotNil(SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Words before abrupt termination")], chat: [],
            sessionId: "invented-session", systemAudioStartOffsetMs: 2_500
        ))
        let listed = SessionArchive.recentSessions(limit: .max)
        XCTAssertEqual(listed.count, 1)
        let listedSession = try XCTUnwrap(listed.first)
        XCTAssertEqual(identity(listedSession.url), identity(directory))
        XCTAssertNotNil(listedSession.date, "The written folder stamp must parse on restart: \(listedSession.url.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: listedSession.url.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: listedSession.url).count, 2)
        let pending = SessionArchive.pendingAutomaticUpgrades()
        XCTAssertEqual(pending.count, 1, "A seeded checkpoint with retained audio must be queued on restart")
        let recovered = try XCTUnwrap(pending.first)
        XCTAssertEqual(identity(recovered.url), identity(directory))
        XCTAssertTrue(try String(contentsOf: recovered.transcriptURL, encoding: .utf8).contains("Words before abrupt termination"))
        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: recovered.url)
        XCTAssertEqual(inputs.map { identity($0.url) }, [identity(audioURL), identity(systemURL)])
        XCTAssertEqual(inputs.map(\.offsetMs), [0, 2_500])
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: systemURL), systemAudio)
        XCTAssertTrue(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(directory) }, "A failed or interrupted retry must remain discoverable")
        SessionArchive.clearAutomaticUpgradePending(in: directory)
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(directory) })
    }

    func testRecoveryDoesNotDropPendingSessionsBehindRecentTwoHundred() throws {
        let old = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        SessionArchive.seedTranscriptForAutomaticUpgrade(in: old, startedAt: startedAt)
        SessionArchive.markAutomaticUpgradePending(in: old)
        try pcmWAV(sample: 21).write(to: old.appendingPathComponent("audio-mic.wav"))
        for index in 1...201 {
            _ = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt.addingTimeInterval(Double(index * 60))))
        }
        XCTAssertEqual(SessionArchive.recentSessions(limit: 200).count, 200)
        let listed = SessionArchive.recentSessions(limit: .max)
        XCTAssertEqual(listed.count, 202)
        let oldSession = try XCTUnwrap(listed.first { identity($0.url) == identity(old) }, "The full archive scan must contain the older session")
        XCTAssertNotNil(oldSession.date, "The older folder stamp must parse on restart")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSession.url.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: oldSession.url).count, 1)
        XCTAssertTrue(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(old) })
    }

    func testKnownRecordingFailurePersistsAndBlocksAutomaticProcessing() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 31)
        try audio.write(to: audioURL)
        let saved = SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Known incomplete capture")], chat: [], sessionId: "needs-review",
            micRecordingURL: audioURL, recordingError: "Injected synchronize failure"
        )
        XCTAssertNotNil(saved)
        XCTAssertEqual(SessionArchive.recordingError(in: directory), "Injected synchronize failure")
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        let session = try XCTUnwrap(SessionArchive.recentSessions().first {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
        let row = SessionsWindowModel.makeRow(session, titleMap: .empty, databases: nil)
        XCTAssertEqual(row.recordingError, "Injected synchronize failure")
        XCTAssertEqual(row.transcriptStatus, "Recording needs review")
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
    }

    func testRecordingFailureUnqueuesAutomaticWorkEvenWhenArchiveWriteAlsoFails() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 47)
        try audio.write(to: audioURL)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.md"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("transcript.md"), withIntermediateDirectories: true)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Incomplete recording")], chat: [], visualContext: [], notes: [],
            sessionId: "manual-review", micRecordingURL: audioURL, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil,
            recordingError: "Injected close failure"
        )
        XCTAssertNil(SessionFinalizer(snapshot: snapshot).archive())
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains {
            $0.url.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        })
    }

    /// F5: a recording that stopped on a write failure takes the review
    /// path. Its notes and typed notes still reach transcripts-raw, no
    /// automatic upgrade is queued, and a later manual export keeps that full
    /// sidecar instead of writing an empty one.
    func testReviewPathStillHandsNotesToMeetingAndManualExportKeepsThem() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let audioURL = directory.appendingPathComponent("audio-mic.wav")
        let audio = pcmWAV(sample: 53)
        try audio.write(to: audioURL)
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented pricing block", content: "- The invented panel preferred option B")
        let typed = LiveEntry(speakerId: "note", text: "Invented typed reminder", startMs: 5_000, confidence: 1,
                              translationStatus: "none", language: nil, sourceLanguage: nil)
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Words before the disk filled"), typed], chat: [], visualContext: [], notes: [note],
            sessionId: "stopped-early", micRecordingURL: audioURL, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: nil,
            recordingError: "Meeting audio could not be saved for 30 seconds (invented ENOSPC), so recording stopped."
        )
        let archived = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        let sidecar = try XCTUnwrap(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: archived, callType: .research))
        XCTAssertEqual(sidecar.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       root.appendingPathComponent("transcripts-raw").resolvingSymlinksInPath().path)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("The invented panel preferred option B"))
        XCTAssertTrue(text.contains("Invented typed reminder"))
        XCTAssertFalse(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(archived) },
                       "files marked for review are never upgraded automatically")
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)

        _ = try SessionArchive.requiredCanonicalExport(in: archived, startedAt: startedAt)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), text, "a manual upgrade keeps the full sidecar")
    }

    /// NET-6: the app died (crash, or a quit before the emergency write)
    /// after a checkpoint, so Stop never wrote the sidecar. The upgrade at the
    /// next launch writes it from what the archive kept: generated notes,
    /// screen context and chat, not empty sections.
    func testRecoverySidecarCarriesTheArchivedNotesChatAndScreenContext() throws {
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented budget block", content: "- Fixture note: budget raised")
        let chat = [
            ChatEntry(role: "user", text: "Invented question about the fixture", action: "Ask", contextUsed: true, screenContextUsed: false),
            ChatEntry(role: "assistant", text: "Invented answer about the fixture", action: nil, contextUsed: false, screenContextUsed: false),
        ]
        let screen = [VisualContextEvent(offsetSeconds: 30, text: "Invented slide: option B pricing")]
        let directory = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented words before the crash")], chat: chat, visualContext: screen, notes: [note],
            sessionId: "crashed", mode: CallType.research.name, evidence: evidence("Invented words before the crash")
        ))
        XCTAssertNil(sidecarFile(), "Stop never ran, so there is no sidecar yet")

        _ = try SessionArchive.requiredCanonicalExport(in: directory, startedAt: startedAt)
        let text = try String(contentsOf: XCTUnwrap(sidecarFile()), encoding: .utf8)
        XCTAssertTrue(text.contains("\ncall_type: research\n"))
        XCTAssertTrue(text.contains("## Generated notes"))
        XCTAssertTrue(text.contains("Fixture note: budget raised"))
        XCTAssertTrue(text.contains("## Screen context"))
        XCTAssertTrue(text.contains("Invented slide: option B pricing"))
        XCTAssertTrue(text.contains("## Assistant chat"))
        XCTAssertTrue(text.contains("Invented answer about the fixture"))
        XCTAssertFalse(text.contains("title: \"RTI session"), "the archive files' own frontmatter stays out")
    }

    /// NET-6: Quit during the finishing window cancels completeStop. The quit
    /// record writes the sidecar itself, and the next launch keeps it.
    func testQuitRecordWritesTheFullSidecarAndRecoveryKeepsIt() throws {
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented closing block", content: "- Fixture note: launch moved to Q3")
        let chat = [ChatEntry(role: "assistant", text: "Invented in-call answer", action: nil, contextUsed: false, screenContextUsed: false)]
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented words before quit")], chat: chat,
            visualContext: [VisualContextEvent(offsetSeconds: 12, text: "Invented shared screen")], notes: [note],
            sessionId: "quit-while-finishing", micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: CallType.client.name
        )
        let record = SessionCoordinator.writeQuitRecord(snapshot: snapshot, callType: .client)
        let archived = try XCTUnwrap(record.archive)
        let sidecar = try XCTUnwrap(record.sidecar)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("Fixture note: launch moved to Q3"))
        XCTAssertTrue(text.contains("Invented in-call answer"))
        XCTAssertTrue(text.contains("Invented shared screen"))
        try evidence("Invented words before quit").write(in: archived)
        _ = try SessionArchive.requiredCanonicalExport(in: archived, startedAt: startedAt)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), text, "the upgrade at next launch keeps the quit sidecar")
    }

    /// F2/F4 (batch 5): the system leg started 8 s after the mic, nobody
    /// has spoken, no note, chat or screen context, and live transcription
    /// may be down. The write the coordinator makes at that moment (and at
    /// launch, at each checkpoint and on quit) still leaves session.json, so a
    /// crash recovers the system leg at 8 s with the speech context and the
    /// speaker policy, and the upgrade writes a sidecar.
    func testAnEmptyLiveWriteStillLeavesTheOffsetAndContextForRecovery() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        try pcmWAV(sample: 41).write(to: directory.appendingPathComponent("audio-mic.wav"))
        try pcmWAV(sample: 42).write(to: directory.appendingPathComponent("audio-system.wav"))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: directory).map(\.offsetMs), [0, 0],
                       "before the write the system leg would be placed 8 s early")

        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(8),
            transcript: [], chat: [], visualContext: [], notes: [],
            sessionId: "invented-silent", micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: 8_000, workstreamItem: nil, modeName: CallType.client.name
        )
        let context = SonioxContext.forMeeting(callType: "Client call", project: nil, meetingTitle: nil,
                                               participants: [], terms: ["Qorvane"])
        let lookup = GuideSessionController.QuestionLookup(hasGuide: false, selections: [], markers: nil)
        let job = SessionFinalizer.Job(
            snapshot: snapshot, sequence: ArchiveWriteGate.shared.nextSequence(), speakerNames: [:], speakerAssignments: [:],
            calendarTitle: nil, speechContext: context,
            evidence: .init(events: [], timeline: MarkerTimeline(events: []), codes: [], namedSpeakers: [], questions: lookup),
            speakerPolicy: SessionSpeakerPolicy(), packageRevision: nil
        )
        XCTAssertEqual(identity(try XCTUnwrap(SessionFinalizer.write(job))), identity(directory))

        let metadata = try sessionMetadata(directory)
        XCTAssertEqual(metadata.sessionId, "invented-silent")
        XCTAssertEqual(metadata.speechContext, context)
        XCTAssertNotNil(metadata.speakerPolicy, "the upgrade picks the raw provider and its policy")
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: directory).map(\.offsetMs), [0, 8_000])
        XCTAssertTrue(SessionArchive.pendingAutomaticUpgrades().contains { identity($0.url) == identity(directory) })

        try writeUpgradedTranscript(in: directory)
        _ = try SessionArchive.requiredCanonicalExport(in: directory, startedAt: startedAt)
        XCTAssertNotNil(sidecarFile(), "a session that died before speech still hands /meeting a sidecar")
    }

    /// F2/F4: Quit Anyway with the same empty state. The quit record writes
    /// session.json from the offset alone; before, it wrote nothing.
    func testQuitWithNoContentStillWritesTheSystemOffset() throws {
        let directory = try XCTUnwrap(SessionArchive.sessionDirectory(startedAt: startedAt))
        try pcmWAV(sample: 43).write(to: directory.appendingPathComponent("audio-system.wav"))
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(20),
            transcript: [], chat: [], visualContext: [], notes: [],
            sessionId: "invented-quit", micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: 8_000, workstreamItem: nil, modeName: CallType.client.name
        )
        XCTAssertNotNil(SessionCoordinator.writeQuitRecord(snapshot: snapshot, callType: .client).archive)
        XCTAssertEqual(try sessionMetadata(directory).systemAudioStartOffsetMs, 8_000)
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: directory).map(\.offsetMs), [8_000])
    }

    /// F1 (batch 5): a crash before any write that kept evidence. The marker
    /// journal and notes.md are on disk; the recovery upgrade still writes a
    /// sidecar that carries the typed note and the generated notes.
    func testRecoverySidecarIsWrittenWithoutAnEvidenceFile() throws {
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented early block", content: "- Fixture note: kickoff moved")
        let directory = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [], chat: [], notes: [note], sessionId: "no-evidence"
        ))
        XCTAssertTrue(SessionArchive.seedTranscriptForAutomaticUpgrade(in: directory, startedAt: startedAt))
        try SessionMarkerJournal.append(SessionNote(id: "typed", kind: .note, offsetMs: 4_000, text: "Invented typed reminder"),
                                        in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SessionEvidence.filename).path))

        try writeUpgradedTranscript(in: directory)
        _ = try SessionArchive.requiredCanonicalExport(in: directory, startedAt: startedAt)
        let text = try String(contentsOf: XCTUnwrap(sidecarFile()), encoding: .utf8)
        XCTAssertTrue(text.contains("Fixture note: kickoff moved"))
        XCTAssertTrue(text.contains("Invented typed reminder"))
    }

    /// F5 (batch 6): config.json was broken by a hand edit (or caught half
    /// rewritten) when the upgrade finished. The export used to read that as
    /// "no meetings folder", return success, and let the caller clear the
    /// marker, so /meeting never ran. Now it fails in plain words, keeps both
    /// retry markers, and the retry after the fix exports and writes the sidecar.
    func testBrokenConfigAtExportKeepsTheRetryAndSaysWhy() throws {
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented config block", content: "- Fixture note: config case")
        let directory = try XCTUnwrap(SessionArchive.write(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented words before the config broke")], chat: [], notes: [note],
            sessionId: "broken-config", evidence: evidence("Invented words before the config broke")
        ))
        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: directory))
        let configURL = root.appendingPathComponent("config/config.json")
        let good = try Data(contentsOf: configURL)
        try Data(#"{"recordings_dir": "/invented/x","#.utf8).write(to: configURL)

        XCTAssertThrowsError(try TranscriptUpgradeService.finishExport(in: directory, startedAt: startedAt, provider: "Fixture", segmentCount: 1)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("could not find the meetings folder"), text)
            XCTAssertTrue(text.contains("is not valid JSON"), text)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("canonical-export.pending.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path))
        XCTAssertNil(sidecarFile())

        // Valid JSON that names no folder fails the same way, with its own reason.
        try JSONSerialization.data(withJSONObject: ["sessions_dir": root.appendingPathComponent("sessions").path]).write(to: configURL)
        XCTAssertThrowsError(try TranscriptUpgradeService.finishExport(in: directory, startedAt: startedAt, provider: "Fixture", segmentCount: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("names no transcripts_dir"), error.localizedDescription)
        }

        try good.write(to: configURL)
        let raw = try XCTUnwrap(TranscriptUpgradeService.finishExport(in: directory, startedAt: startedAt, provider: "Fixture", segmentCount: 1))
        XCTAssertTrue(try String(contentsOf: raw, encoding: .utf8).contains("Invented words before the config broke"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("canonical-export.pending.json").path))
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(sidecarFile()), encoding: .utf8).contains("Fixture note: config case"))
    }

    /// F6 (batch 6): Stop could not write the sidecar (a folder sits at its
    /// path, as when the disk or mount refuses the file). That is no longer
    /// silent: the export after the upgrade fails and keeps the retry, and
    /// once the path is free it writes the sidecar from the archive with the
    /// generated notes, the screen context and the chat. A recording marked
    /// for review, which runs no upgrade, says so in its error.
    func testFailedStopSidecarIsRetriedByTheExportWithTheArchivedSections() throws {
        let note = GeneratedNote(timestamp: startedAt, rangeStartMs: 0, rangeEndMs: 60_000,
                                 title: "Invented stop block", content: "- Fixture note: sidecar refused")
        let chat = [ChatEntry(role: "assistant", text: "Invented stop answer", action: nil, contextUsed: false, screenContextUsed: false)]
        let snapshot = SessionFinalizer.Snapshot(
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
            transcript: [entry("Invented words at stop")], chat: chat,
            visualContext: [VisualContextEvent(offsetSeconds: 9, text: "Invented stop slide")], notes: [note],
            sessionId: "stop-sidecar-refused", micRecordingURL: nil, systemRecordingURL: nil,
            systemAudioStartOffsetMs: nil, workstreamItem: nil, modeName: CallType.client.name
        )
        let archived = try XCTUnwrap(SessionFinalizer(snapshot: snapshot).archive())
        try evidence("Invented words at stop").write(in: archived)
        let path = try XCTUnwrap(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: archived, callType: .client))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertNil(SessionCoordinator.writeStopSidecar(snapshot: snapshot, archiveDir: archived, callType: .client),
                     "precondition: the stop write fails")
        XCTAssertTrue(SessionCoordinator.archiveSaveFailureMessage(recordingError: "Invented error.", sidecarMissing: true)
            .contains("The notes file for /meeting was not written"))
        XCTAssertFalse(SessionCoordinator.archiveSaveFailureMessage(recordingError: "Invented error.", sidecarMissing: false)
            .contains("/meeting"))

        XCTAssertTrue(SessionArchive.markAutomaticUpgradePending(in: archived))
        XCTAssertThrowsError(try TranscriptUpgradeService.finishExport(in: archived, startedAt: startedAt, provider: "Fixture", segmentCount: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("canonical-export.pending.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("automatic-upgrade.pending").path))

        try FileManager.default.removeItem(at: path)
        XCTAssertNotNil(try TranscriptUpgradeService.finishExport(in: archived, startedAt: startedAt, provider: "Fixture", segmentCount: 1))
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.contains("Fixture note: sidecar refused"), text)
        XCTAssertTrue(text.contains("Invented stop slide"), text)
        XCTAssertTrue(text.contains("Invented stop answer"), text)
    }

    /// What the recovery upgrade leaves before it exports.
    private func writeUpgradedTranscript(in directory: URL) throws {
        try "# Transcript\n\n_Upgraded with Soniox._\n\n`0:09` **Remote speaker 1:** Invented upgraded words\n"
            .write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    private func sessionMetadata(_ directory: URL) throws -> SessionArchiveMetadata {
        try JSONDecoder().decode(SessionArchiveMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
    }

    private func evidence(_ text: String) -> SessionEvidence {
        let turn = SessionAnnotatedTurn(turnID: "self@0", rawSpeaker: "self", leg: "Me", speakerConfidence: "unverified",
                                        original: text, liveStartMs: 0, endMs: 1_000,
                                        context: MarkerTimeline(events: []).context(at: 0))
        return SessionEvidence(sessionID: "fixture", groupID: nil, events: [], through: 60_000, turns: [turn])
    }

    private func sidecarFile() -> URL? {
        let raw = root.appendingPathComponent("transcripts-raw")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? []
        return names.first { $0.hasSuffix("-rti.md") }.map { raw.appendingPathComponent($0) }
    }

    private func archive(transcript: [LiveEntry], mic: URL? = nil) -> URL? {
        SessionArchive.write(startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60), transcript: transcript, chat: [], sessionId: "invented-session", micRecordingURL: mic)
    }

    private func entry(_ text: String) -> LiveEntry {
        LiveEntry(speakerId: "self", text: text, startMs: 0, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    private func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pcmWAV(sample: Int16) -> Data {
        let sampleCount: UInt32 = 160
        var data = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); bytes(UInt32(36) + sampleCount * 2)
        data.append(Data("WAVEfmt ".utf8)); bytes(UInt32(16))
        bytes(UInt16(1)); bytes(UInt16(1)); bytes(UInt32(16_000)); bytes(UInt32(32_000))
        bytes(UInt16(2)); bytes(UInt16(16)); data.append(Data("data".utf8)); bytes(sampleCount * 2)
        for _ in 0..<sampleCount { bytes(sample) }
        return data
    }
}
