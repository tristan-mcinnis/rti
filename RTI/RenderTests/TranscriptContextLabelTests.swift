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
