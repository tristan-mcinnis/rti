import XCTest

/// Pins `session.json`'s shape: the mode/workstream/duration fields
/// round-trip, and legacy archives (written before this fix, missing
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
            durationSeconds: 1800
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(SessionArchiveMetadata.self, from: data)
        XCTAssertEqual(decoded.mode, "Meeting")
        XCTAssertEqual(decoded.workstream, "Acme Brand")
        XCTAssertEqual(decoded.durationSeconds, 1800)
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
        XCTAssertNil(decoded.calendarTitle)
    }

    func testCalendarTitleRoundTripsAndDefaultsToNil() throws {
        let plain = SessionArchiveMetadata(
            sessionId: "abc123", systemAudioStartOffsetMs: nil, micAudioFile: nil,
            systemAudioFile: nil, mode: nil, workstream: nil, durationSeconds: 60
        )
        XCTAssertNil(plain.calendarTitle)

        let withEvent = SessionArchiveMetadata(
            sessionId: "abc123", systemAudioStartOffsetMs: nil, micAudioFile: nil,
            systemAudioFile: nil, mode: "Meeting", workstream: nil, durationSeconds: 60,
            calendarTitle: "Weekly sync"
        )
        let decoded = try JSONDecoder().decode(SessionArchiveMetadata.self, from: JSONEncoder().encode(withEvent))
        XCTAssertEqual(decoded.calendarTitle, "Weekly sync")
    }
}
