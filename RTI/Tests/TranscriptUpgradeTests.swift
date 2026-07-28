import XCTest
@testable import RTICore

final class TranscriptUpgradeTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        var value: T

        init(_ value: T) {
            self.value = value
        }
    }

    func testSessionTranscriptReviewReassignsAndEditsTurnsWithoutChangingProvenance() {
        let markdown = """
        ---
        title: "RTI session"
        ---

        # Transcript

        _Upgraded with Soniox._

        `0:04` **Speaker 1:** rough live text

        `0:07` **📝 Note:** Preserve this note.

        `1:02` **Speaker 2:** follow-up

        _Footer stays put._
        """

        var turns = SessionTranscriptReview.turns(from: markdown)
        XCTAssertEqual(turns.map(\.speaker), ["Speaker 1", "📝 Note", "Speaker 2"])
        turns[0].speaker = "Rossi"
        turns[0].text = "Corrected opening."

        let updated = SessionTranscriptReview.replacingTurns(in: markdown, with: turns)

        XCTAssertTrue(updated.contains("`0:04` **Rossi:** Corrected opening."))
        XCTAssertTrue(updated.contains("`0:07` **📝 Note:** Preserve this note."))
        XCTAssertTrue(updated.contains("_Upgraded with Soniox._"))
        XCTAssertTrue(updated.contains("_Footer stays put._"))
    }

    func testCanonicalMeetingTranscriptRendersLiveEntriesLikeSentinelRawTranscript() {
        let entries = [
            LiveEntry(speakerId: "self", text: "Opening note.", startMs: 1_000, confidence: 0.9, translationStatus: "original", language: "en", sourceLanguage: nil),
            LiveEntry(speakerId: "note", text: "This is a typed note.", startMs: 2_000, confidence: 1, translationStatus: "none", language: nil, sourceLanguage: nil),
            LiveEntry(speakerId: "remote_1", text: "Let's begin.", startMs: 61_000, confidence: 0.9, translationStatus: "original", language: "en", sourceLanguage: nil),
            LiveEntry(speakerId: "remote_1", text: "Empecemos.", startMs: 61_000, confidence: 0.9, translationStatus: "translation", language: "es", sourceLanguage: "en")
        ]

        let text = CanonicalMeetingTranscript.render(entries: entries)

        XCTAssertEqual(text, """
        [00:01] Speaker 1: Opening note.

        [01:01] Speaker 2: Let's begin.
        """)
    }

    func testCanonicalMeetingTranscriptConvertsArchivedMarkdownAndSkipsNotes() {
        let markdown = """
        ---
        title: "RTI session"
        ---

        # Transcript

        _Jul 6, 2026_

        `0:04` **Speaker 1:** rough live text

        `0:07` **📝 Note:** Preserve this only in sidecar.

        `1:02` **Speaker 2:** follow-up
        """

        let text = CanonicalMeetingTranscript.render(markdownTranscript: markdown)

        XCTAssertEqual(text, """
        [00:04] Speaker 1: rough live text

        [01:02] Speaker 2: follow-up
        """)
    }

    func testExtractsInlineNotesFromArchivedTranscript() {
        let markdown = """
        # Transcript

        `0:04` **Speaker 1:** hello

        `0:07` **📝 Note:** Ask about pricing.

        `1:02` **📝 Note:** Follow up with Dana.
        """

        let notes = TranscriptUpgradeMerge.notes(from: markdown)

        XCTAssertEqual(notes, [
            TranscriptUpgradeNote(startMs: 7_000, text: "Ask about pricing."),
            TranscriptUpgradeNote(startMs: 62_000, text: "Follow up with Dana.")
        ])
    }

    func testParsesTimestampedProviderSegments() {
        let text = """
        [00:03] Speaker 1: Welcome everyone.
        [00:10] Speaker 2: 我们开始吧。
        00:15 Speaker 1: Next item.
        """

        let segments = TranscriptUpgradeMerge.segments(from: text, offsetMs: 2_000)

        XCTAssertEqual(segments, [
            TranscriptUpgradeSegment(speaker: "Speaker 1", startMs: 5_000, text: "Welcome everyone."),
            TranscriptUpgradeSegment(speaker: "Speaker 2", startMs: 12_000, text: "我们开始吧。"),
            TranscriptUpgradeSegment(speaker: "Speaker 1", startMs: 17_000, text: "Next item.")
        ])
    }

    func testRenderPlacesNotesInTimestampOrder() {
        let startedAt = Date(timeIntervalSince1970: 0)
        let body = TranscriptUpgradeMerge.renderBody(
            startedAt: startedAt,
            endedAt: nil,
            segments: [
                TranscriptUpgradeSegment(speaker: "Speaker 1", startMs: 1_000, text: "Before note."),
                TranscriptUpgradeSegment(speaker: "Speaker 2", startMs: 9_000, text: "After note.")
            ],
            notes: [TranscriptUpgradeNote(startMs: 5_000, text: "Important user note.")],
            provider: "Soniox",
            sourceFiles: ["audio-mic.m4a"],
            generatedAt: startedAt
        )

        let before = body.range(of: "Before note.")!.lowerBound
        let note = body.range(of: "Important user note.")!.lowerBound
        let after = body.range(of: "After note.")!.lowerBound
        XCTAssertLessThan(before, note)
        XCTAssertLessThan(note, after)
        XCTAssertTrue(body.contains("Upgraded with Soniox"))
    }

    func testInstallUpgradedTranscriptKeepsRecoverableArtifacts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-upgrade-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("transcript.md")
        let summary = dir.appendingPathComponent("summary.md")
        try "old transcript".write(to: transcript, atomically: true, encoding: .utf8)
        try "old summary".write(to: summary, atomically: true, encoding: .utf8)

        let result = try TranscriptUpgradeArtifacts.installUpgradedTranscript(
            markdown: "new transcript",
            in: dir,
            backupStamp: "20260630-120000"
        )

        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "new transcript")
        XCTAssertEqual(try String(contentsOf: result.upgradedURL, encoding: .utf8), "new transcript")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.transcriptBackupURL), encoding: .utf8), "old transcript")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.summaryBackupURL), encoding: .utf8), "old summary")
    }

    func testAudioDiscoveryUsesSessionMetadataAndOffsets() throws {
        let dir = try makeTemporarySessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("mic".utf8).write(to: dir.appendingPathComponent("mic-retained.m4a"))
        try Data("system".utf8).write(to: dir.appendingPathComponent("system-retained.m4a"))
        try """
        {
          "sessionId": "session-1",
          "systemAudioStartOffsetMs": 4500,
          "micAudioFile": "mic-retained.m4a",
          "systemAudioFile": "system-retained.m4a"
        }
        """.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: dir)

        XCTAssertEqual(inputs, [
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent("mic-retained.m4a"), offsetMs: 0),
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent("system-retained.m4a"), offsetMs: 4_500)
        ])
    }

    func testAudioDiscoveryConfinesMetadataNamesToSessionFolder() throws {
        let dir = try makeTemporarySessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("mic".utf8).write(to: dir.appendingPathComponent("outside.m4a"))
        try """
        {
          "micAudioFile": "../outside.m4a",
          "systemAudioFile": "/tmp/not-session-local.m4a"
        }
        """.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: dir)

        XCTAssertEqual(inputs, [
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent("outside.m4a"), offsetMs: 0)
        ])
    }

    func testAudioDiscoveryDedupesSameMetadataFile() throws {
        let dir = try makeTemporarySessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("audio".utf8).write(to: dir.appendingPathComponent("shared.m4a"))
        try """
        {
          "micAudioFile": "shared.m4a",
          "systemAudioFile": "shared.m4a",
          "systemAudioStartOffsetMs": 9000
        }
        """.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let inputs = TranscriptUpgradeAudioDiscovery.inputs(in: dir)

        XCTAssertEqual(inputs, [
            TranscriptUpgradeAudioInput(url: dir.appendingPathComponent("shared.m4a"), offsetMs: 0)
        ])
    }

    func testPipelineUpgradesArchivedSessionEndToEndWithFakeProvider() async throws {
        let dir = try makeTemporarySessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        # Transcript

        `0:01` **Speaker 1:** rough live text

        `0:03` **📝 Note:** Preserve this user note.
        """.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try "old summary".write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try Data("mic".utf8).write(to: dir.appendingPathComponent("audio-mic.m4a"))
        try Data("system".utf8).write(to: dir.appendingPathComponent("audio-system.m4a"))
        try """
        {
          "systemAudioStartOffsetMs": 4000,
          "micAudioFile": "audio-mic.m4a",
          "systemAudioFile": "audio-system.m4a"
        }
        """.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let progress = Box<[String]>([])
        let transcribed = Box<[String]>([])
        let routerRuns = Box(0)
        let startedAt = Date(timeIntervalSince1970: 1_782_000_000)
        let summaryURL = dir.appendingPathComponent("summary.md")

        let result = try await TranscriptUpgradePipeline.upgrade(
            sessionDir: dir,
            startedAt: startedAt,
            providerID: "fake_provider",
            providerDisplayName: "Fake Provider",
            frontmatter: ["---", "kind: Transcript", "---", ""],
            progress: { progress.value.append($0) },
            transcribe: { audioURL, _ in
                transcribed.value.append(audioURL.lastPathComponent)
                if audioURL.lastPathComponent == "audio-system.m4a" {
                    return "[00:01] Speaker 2: System audio upgraded."
                }
                return "[00:01] Speaker 1: Mic audio upgraded."
            },
            writeSummary: { transcriptText in
                try? "summary from upgraded transcript\n\(transcriptText)".write(to: summaryURL, atomically: true, encoding: .utf8)
                return summaryURL
            },
            runRouter: {
                routerRuns.value += 1
            }
        )

        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.summaryURL, summaryURL)
        XCTAssertEqual(result.sourceFiles, ["audio-mic.m4a", "audio-system.m4a"])
        XCTAssertEqual(transcribed.value, ["audio-mic.m4a", "audio-system.m4a"])
        XCTAssertEqual(routerRuns.value, 1)
        XCTAssertTrue(progress.value.contains("Writing upgraded transcript"))
        XCTAssertTrue(progress.value.contains("Regenerating summary"))

        let transcript = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(transcript.contains("Upgraded with Fake Provider"))
        XCTAssertTrue(transcript.contains("Source audio: audio-mic.m4a, audio-system.m4a"))
        XCTAssertTrue(transcript.contains("`0:01` **Speaker 1:** Mic audio upgraded."))
        XCTAssertTrue(transcript.contains("`0:03` **📝 Note:** Preserve this user note."))
        XCTAssertTrue(transcript.contains("`0:05` **Speaker 2:** System audio upgraded."))

        let mic = transcript.range(of: "Mic audio upgraded.")!.lowerBound
        let note = transcript.range(of: "Preserve this user note.")!.lowerBound
        let system = transcript.range(of: "System audio upgraded.")!.lowerBound
        XCTAssertLessThan(mic, note)
        XCTAssertLessThan(note, system)

        XCTAssertEqual(try String(contentsOf: result.artifactResult.upgradedURL, encoding: .utf8), transcript)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(result.artifactResult.transcriptBackupURL), encoding: .utf8),
            """
            # Transcript

            `0:01` **Speaker 1:** rough live text

            `0:03` **📝 Note:** Preserve this user note.
            """
        )
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.artifactResult.summaryBackupURL), encoding: .utf8), "old summary")
        XCTAssertTrue(try String(contentsOf: summaryURL, encoding: .utf8).contains("summary from upgraded transcript"))
    }

    func testPipelineLeavesTranscriptUnchangedWhenProviderReturnsEmptyText() async throws {
        let dir = try makeTemporarySessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try "old transcript".write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data("mic".utf8).write(to: dir.appendingPathComponent("audio-mic.m4a"))

        do {
            _ = try await TranscriptUpgradePipeline.upgrade(
                sessionDir: dir,
                startedAt: Date(timeIntervalSince1970: 0),
                providerID: "empty_provider",
                providerDisplayName: "Empty Provider",
                frontmatter: [],
                progress: { _ in },
                transcribe: { _, _ in "" },
                writeSummary: { _ in XCTFail("Summary should not regenerate for empty provider output"); return nil },
                runRouter: { XCTFail("Router should not run for empty provider output") }
            )
            XCTFail("Expected empty provider output to fail")
        } catch let error as TranscriptUpgradePipelineError {
            XCTAssertEqual(error, .emptyTranscript("Empty Provider"))
        }

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8), "old transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.upgraded.md").path))
    }

    private func makeTemporarySessionDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-upgrade-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
