import XCTest
import RTICore

final class SpeakerTurnTests: XCTestCase {

    private func word(_ text: String, speaker: Int, start: Int, end: Int, confidence: Double = 1.0) -> SonioxWord {
        SonioxWord(text: text, startMs: start, endMs: end, speaker: speaker, confidence: confidence, isFinal: true, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    func test_emptyInput_returnsEmpty() {
        XCTAssertTrue(SpeakerTurn.collapse([]).isEmpty)
    }

    func test_singleWord_singleTurn() {
        let words = [word("hi", speaker: 0, start: 0, end: 100, confidence: 0.9)]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].speaker, 0)
        XCTAssertEqual(turns[0].text, "hi")
        XCTAssertEqual(turns[0].startMs, 0)
        XCTAssertEqual(turns[0].endMs, 100)
        XCTAssertEqual(turns[0].confidence, 0.9, accuracy: 1e-9)
    }

    func test_twoSameSpeakerWords_oneTurn() {
        let words = [
            word("hello ", speaker: 0, start: 0, end: 100),
            word("world", speaker: 0, start: 100, end: 250)
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "hello world")
        XCTAssertEqual(turns[0].startMs, 0)
        XCTAssertEqual(turns[0].endMs, 250)
    }

    func test_alternatingSpeakers_threeTurns() {
        let words = [
            word("hi", speaker: 0, start: 0, end: 50),
            word("yo", speaker: 1, start: 50, end: 100),
            word("ok", speaker: 0, start: 100, end: 150)
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map(\.speaker), [0, 1, 0])
        XCTAssertEqual(turns.map(\.text), ["hi", "yo", "ok"])
    }

    func test_confidenceAveragedUnweighted() {
        let words = [
            word("a", speaker: 0, start: 0, end: 10, confidence: 1.0),
            word("b", speaker: 0, start: 10, end: 20, confidence: 0.5),
            word("c", speaker: 0, start: 20, end: 30, confidence: 0.5),
            word("d", speaker: 0, start: 30, end: 40, confidence: 0.0)
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].confidence, 0.5, accuracy: 1e-9)
    }
}
