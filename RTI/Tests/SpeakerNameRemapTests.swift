@testable import RTICore
import XCTest

/// Typed names follow their voices when the upgrade renumbers the other
/// side's speakers. Invented names and text only.
final class SpeakerNameRemapTests: XCTestCase {
    private func turn(_ speaker: String, _ seconds: Int) -> TranscriptUpgradeSegment {
        TranscriptUpgradeSegment(speaker: speaker, startMs: seconds * 1000, text: "words")
    }

    func testEachLiveVoiceMovesToTheUpgradedVoiceAtTheSameTimes() {
        let live = [turn("Remote speaker 1", 0), turn("Remote speaker 2", 20), turn("Remote speaker 1", 40), turn("Remote speaker 2", 60)]
        let upgraded = [turn("Remote speaker 2", 1), turn("Remote speaker 1", 21), turn("Remote speaker 2", 41), turn("Remote speaker 1", 61)]
        XCTAssertEqual(SpeakerNameRemap.mapping(live: live, upgraded: upgraded),
                       ["Remote speaker 1": "Remote speaker 2", "Remote speaker 2": "Remote speaker 1"])
    }

    func testAnUnclearOrSharedMatchDropsTheName() {
        // Live 1 and live 2 both sit mostly on upgraded 1: only the larger
        // overlap keeps it. Live 3 splits evenly: no clear voice.
        let live = [turn("Remote speaker 1", 0), turn("Remote speaker 2", 25), turn("Remote speaker 3", 40)]
        let upgraded = [turn("Remote speaker 1", 0), turn("Remote speaker 1", 20), turn("Remote speaker 2", 45), turn("Remote speaker 4", 55)]
        let mapping = SpeakerNameRemap.mapping(live: live, upgraded: upgraded)
        XCTAssertEqual(mapping["Remote speaker 1"], "Remote speaker 1")
        XCTAssertNil(mapping["Remote speaker 2"])
        XCTAssertNil(mapping["Remote speaker 3"])

        let names = SpeakerNameArchive(names: ["remote_1": "Ada", "remote_2": "Ben", "room_1": "Cy"])
        let remapped = SpeakerNameRemap.remap(names, mapping: ["Remote speaker 2": "Remote speaker 5"])
        XCTAssertEqual(remapped.names, ["remote_5": "Ben", "room_1": "Cy"], "unmatched remote names drop; mic names stay")
    }

    func testTheUpgradeRewritesNamesAndKeepsTheLiveMap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rti-remap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        # Transcript

        `0:01` **Remote speaker 1:** first voice
        `0:20` **Remote speaker 2:** second voice
        `0:40` **Remote speaker 1:** first voice again
        """.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data("system".utf8).write(to: dir.appendingPathComponent("audio-system.m4a"))
        try #"{"systemAudioFile": "audio-system.m4a", "systemAudioStartOffsetMs": 0}"#
            .write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(SpeakerNameArchive(names: ["remote_1": "Ada Example"]))
            .write(to: dir.appendingPathComponent("speaker-names.json"))

        _ = try await TranscriptUpgradePipeline.upgrade(
            sessionDir: dir, startedAt: Date(timeIntervalSince1970: 1_782_000_000), providerID: "fixture",
            providerDisplayName: "Fixture", frontmatter: [], progress: { _ in },
            transcribe: { _, _ in "[00:01] Speaker 2: first voice\n[00:20] Speaker 1: second voice\n[00:40] Speaker 2: first voice again" }
        )

        let names = try JSONDecoder().decode(SpeakerNameArchive.self, from: Data(contentsOf: dir.appendingPathComponent("speaker-names.json")))
        XCTAssertEqual(names.names, ["remote_2": "Ada Example"])
        let live = try JSONDecoder().decode(SpeakerNameArchive.self,
                                            from: Data(contentsOf: dir.appendingPathComponent(SpeakerNameRemap.liveFileName)))
        XCTAssertEqual(live.names, ["remote_1": "Ada Example"], "the live map is kept")
    }

    func testAGuidedSessionKeepsItsNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rti-remap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "`0:01` **Remote speaker 1:** words\n".write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try #"{"guide_path": "/tmp/invented-guide.json"}"#.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(TranscriptUpgradePipeline.liveSystemTurns(in: dir, evidence: nil))
    }
}
