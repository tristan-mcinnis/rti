import XCTest
import RTICore

final class SpeakerTurnTests: XCTestCase {

    private func word(_ text: String, speaker: Int, start: Int, end: Int, confidence: Double = 1.0) -> SonioxWord {
        SonioxWord(text: text, startMs: start, endMs: end, speaker: speaker, confidence: confidence, isFinal: true, translationStatus: "none", language: nil, sourceLanguage: nil)
    }

    private func labelled(_ text: String, language: String, translationStatus: String, start: Int) -> SonioxWord {
        SonioxWord(
            text: text, startMs: start, endMs: start + 100, speaker: 1, confidence: 1, isFinal: true,
            translationStatus: translationStatus, language: language, sourceLanguage: nil
        )
    }

    func test_codeSwitchedSentenceWithoutTranslation_staysOneRow() {
        let turns = SpeakerTurn.collapse([
            labelled("我们看 ", language: "zh", translationStatus: "none", start: 0),
            labelled("brand ", language: "en", translationStatus: "none", start: 100),
            labelled("定位", language: "zh", translationStatus: "none", start: 200),
        ])

        XCTAssertEqual(turns.map(\.text), ["我们看 brand 定位"])
    }

    func test_translatedWords_stillSplitOnLanguage() {
        let turns = SpeakerTurn.collapse([
            labelled("你好 ", language: "zh", translationStatus: "original", start: 0),
            labelled("hello ", language: "en", translationStatus: "original", start: 100),
        ])

        XCTAssertEqual(turns.count, 2)
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
            word("hi", speaker: 1, start: 0, end: 50),
            word("yo", speaker: 2, start: 50, end: 100),
            word("ok", speaker: 1, start: 100, end: 150)
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.map(\.speaker), [1, 2, 1])
        XCTAssertEqual(turns.map(\.text), ["hi", "yo", "ok"])
    }

    /// A token Soniox left unlabelled (speaker 0) stays in the turn around it
    /// instead of splitting one voice into two speakers mid-sentence.
    func test_unlabelledTokenStaysInItsTurn() {
        let words = [
            word("We ", speaker: 2, start: 0, end: 50),
            word("can ", speaker: 0, start: 50, end: 100),
            word("ship.", speaker: 2, start: 100, end: 150),
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.map(\.speaker), [2])
        XCTAssertEqual(turns.map(\.text), ["We can ship."])
    }

    /// A turn that opens unlabelled takes the first label it meets.
    func test_unlabelledOpeningTakesTheNextLabel() {
        let words = [
            word("So ", speaker: 0, start: 0, end: 50),
            word("yes", speaker: 3, start: 50, end: 100),
            word(" no", speaker: 1, start: 100, end: 150),
        ]
        let turns = SpeakerTurn.collapse(words)
        XCTAssertEqual(turns.map(\.speaker), [3, 1])
        XCTAssertEqual(turns.map(\.text), ["So yes", " no"])
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
