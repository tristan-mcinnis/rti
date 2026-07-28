import XCTest

/// Pins `session.json`'s shape: the new mode/workstream/duration/linked_meeting
/// fields round-trip, and legacy archives (written before this fix, missing
/// those keys) still decode — `TranscriptUpgrade` reads this same struct.
final class SessionArchiveMetadataTests: XCTestCase {
    func testEnrichedMetadataRoundTrips() throws {
        let metadata = SessionArchiveMetadata(
            sessionId: "abc123",
            systemAudioStartOffsetMs: 500,
            micAudioFile: "audio-mic.m4a",
            systemAudioFile: "audio-system.m4a",
            mode: "Meeting",
            workstream: "Acme Brand",
            durationSeconds: 1800,
            linkedMeeting: "2026-07-08 Acme sync"
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(SessionArchiveMetadata.self, from: data)
        XCTAssertEqual(decoded.mode, "Meeting")
        XCTAssertEqual(decoded.workstream, "Acme Brand")
        XCTAssertEqual(decoded.durationSeconds, 1800)
        XCTAssertEqual(decoded.linkedMeeting, "2026-07-08 Acme sync")
    }

    func testLegacySessionJSONWithoutNewFieldsStillDecodes() throws {
        let legacy = """
        {"sessionId":"abc123","systemAudioStartOffsetMs":500,"micAudioFile":"audio-mic.m4a","systemAudioFile":"audio-system.m4a"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionArchiveMetadata.self, from: legacy)
        XCTAssertEqual(decoded.sessionId, "abc123")
        XCTAssertNil(decoded.mode)
        XCTAssertNil(decoded.workstream)
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertNil(decoded.linkedMeeting)
    }
}
