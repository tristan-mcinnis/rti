import RTICore
import XCTest

/// The transcript the assistant reads names speakers exactly as the
/// Transcript tab does: by speaker id, with the user's live names.
@MainActor
final class TranscriptContextLabelTests: XCTestCase {
    override func tearDown() async throws {
        SpeakerNameStore.shared.reset()
        try await super.tearDown()
    }

    private func entry(_ speaker: String, _ text: String, _ start: Int) -> LiveEntry {
        LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1,
                  translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    func testLabelsMatchTheTranscriptTabWhoeverSpeaksFirst() {
        let text = TranscriptContext.format([
            entry("remote_2", "Morning.", 1_000),
            entry("self", "Hi both.", 2_000),
            entry("remote_1", "Hello.", 3_000),
        ])
        XCTAssertEqual(text, "Speaker 2: Morning.\nMe: Hi both.\nSpeaker 1: Hello.")
    }

    func testLiveNamesReachTheAssistant() {
        SpeakerNameStore.shared.rename("remote_1", to: "Priya Shah")
        let text = TranscriptContext.format([entry("remote_1", "Yes.", 1_000), entry("room_1", "Agreed.", 2_000)])
        XCTAssertEqual(text, "Priya Shah: Yes.\nRoom speaker 1: Agreed.")
    }
}

/// The archived transcript prints the leg-aware labels that key
/// speaker-names.json and that the vault's speaker-profiles.py reads the audio
/// leg from, whoever speaks first, and keeps names out of the file.
final class ArchivedTranscriptLabelTests: XCTestCase {
    private func entry(_ speaker: String, _ text: String, _ start: Int) -> LiveEntry {
        LiveEntry(speakerId: speaker, text: text, startMs: start, confidence: 1,
                  translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    func testArchiveLabelsComeFromTheSpeakerIdAndLeg() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let text = SessionArchive.renderTranscript(startedAt: start, endedAt: start.addingTimeInterval(120), entries: [
            entry("remote_2", "Morning.", 1_000),
            entry("self", "Hi both.", 2_000),
            entry("remote_1", "Hello.", 3_000),
            entry("remote_1", "Shall we start?", 3_500),
            entry("room_1", "I'm in the room.", 4_000),
            entry("note", "Ask about pricing.", 5_000),
        ])
        XCTAssertTrue(text.contains("**Remote speaker 2:** Morning."))
        XCTAssertTrue(text.contains("**You:** Hi both."))
        XCTAssertTrue(text.contains("**Remote speaker 1:** Hello. Shall we start?"))
        XCTAssertTrue(text.contains("**Room speaker 1:** I'm in the room."))
        XCTAssertTrue(text.contains("**📝 Note:** Ask about pricing."))
        XCTAssertEqual(
            SpeakerLabelMapping.archivedSpeakerLabels(in: text),
            ["Room speaker 1", "Remote speaker 1", "Remote speaker 2"]
        )
    }

    /// speaker-names.json drops `self`, so a name the user gave the mic
    /// wearer live is kept in the transcript itself; other names stay out.
    func testArchiveKeepsANameGivenToTheMicWearer() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let text = SessionArchive.renderTranscript(startedAt: start, endedAt: start.addingTimeInterval(60), entries: [
            entry("self", "Welcome, everyone.", 1_000),
            entry("remote_1", "Thanks.", 2_000),
        ], selfName: " Priya ")
        XCTAssertTrue(text.contains("**Priya:** Welcome, everyone."))
        XCTAssertTrue(text.contains("**Remote speaker 1:** Thanks."))
        XCTAssertFalse(text.contains("**You:**"))
    }
}
