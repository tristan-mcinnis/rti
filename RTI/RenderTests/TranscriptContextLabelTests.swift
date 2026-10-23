import Observation
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

    func testNotesContextKeepsWordsWholeAcrossFinalMessagesWhileTranscriptIsHidden() async throws {
        try RenderProofHarness.prepare()
        let session = SessionCoordinator.shared
        session.beginTranscriptReplayForProof()
        defer { session.endTranscriptReplayForProof() }

        try await SplitWordTranscriptReplay.publish(in: session)

        let text = TranscriptContext.text(forSessionId: try XCTUnwrap(session.currentSessionId))
        XCTAssertTrue(text.contains("Avery: The blue lantern prototype is ready."),
                      "A provider packet boundary must not insert a label or newline inside lantern: \(text)")
        XCTAssertTrue(text.contains("Taylor: The battery test starts tomorrow."))
        XCTAssertFalse(text.contains("TRANSLATION_ONLY_MARKER"))
        XCTAssertFalse(text.contains("PENDING_ONLY_MARKER"))
        XCTAssertFalse(text.contains("remote_1:"))
        XCTAssertFalse(text.contains("self:"))
        XCTAssertTrue(session.transcriptRows.isEmpty, "Notes must not depend on opening Transcript")
    }
}

/// Shared by the Notes-context and actual Ask-request regressions. The invented
/// live-provider fixture finalized " lan" and "tern" in separate messages.
@MainActor
enum SplitWordTranscriptReplay {
    static func publish(in session: SessionCoordinator) async throws {
        // Retire any reader a preceding test owned without opening a view.
        let owner = UUID()
        session.activateTranscriptPresentation(for: owner)
        session.deactivateTranscriptPresentation(for: owner)
        let hiddenRevision = session.transcriptDisplayRevision

        try await publishFinals(in: session) {
            session.receiveTranscriptWordsForProof([
                word("The", start: 900, end: 960),
                word(" blue", start: 1140, end: 1320),
                word(" lan", start: 1440, end: 1500),
            ], channel: "mic")
            XCTAssertTrue(session.liveEntries.isEmpty, "Final publication must use the real coalescer")
        }
        XCTAssertEqual(session.liveEntries.first?.text, "The blue lan")

        try await publishFinals(in: session) {
            session.receiveTranscriptWordsForProof([
                word("The battery test starts tomorrow.", start: 1550, end: 2600),
                word("TRANSLATION_ONLY_MARKER", start: 2650, end: 2800, translation: true),
            ], channel: "system")
            session.receiveTranscriptWordsForProof([
                word("tern", start: 1620, end: 1680),
                word(" prototype is ready.", start: 1920, end: 3120),
                word("PENDING_ONLY_MARKER", start: 5000, end: 5200, final: false),
            ], channel: "mic")
        }
        // Resolve names after publication, as a user rename would.
        SpeakerNameStore.shared.rename("self", to: "Avery")
        SpeakerNameStore.shared.rename("remote_1", to: "Taylor")
        XCTAssertEqual(session.transcriptDisplayRevision, hiddenRevision)
        XCTAssertTrue(session.transcriptRows.isEmpty)
        XCTAssertFalse(session.interimSegments.isEmpty, "The excluded interim must actually be present")
        XCTAssertTrue(session.liveEntries.contains { $0.translationStatus == "translation" },
                      "The excluded translation must actually be present")
    }

    private static func publishFinals(in session: SessionCoordinator, receive: () -> Void) async throws {
        let published = XCTestExpectation(description: "Coalesced final transcript publication")
        withObservationTracking {
            _ = session.transcriptRevision
        } onChange: {
            published.fulfill()
        }
        receive()
        let result = await XCTWaiter.fulfillment(of: [published], timeout: 3)
        guard result == .completed else {
            XCTFail("The real transcript publisher did not commit the fixture")
            throw PublicationTimeout()
        }
    }

    private struct PublicationTimeout: Error {}

    private static func word(_ text: String, start: Int, end: Int, final: Bool = true, translation: Bool = false) -> SonioxWord {
        SonioxWord(text: text, startMs: start, endMs: end, speaker: 1, confidence: 1,
                   isFinal: final, translationStatus: translation ? "translation" : "original",
                   language: translation ? "zh" : "en", sourceLanguage: translation ? "en" : nil)
    }
}

/// The archived transcript prints the leg-aware labels that key
/// speaker-names.json, whoever speaks first, and keeps names out of the file.
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
