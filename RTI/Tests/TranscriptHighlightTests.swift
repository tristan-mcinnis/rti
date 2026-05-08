import XCTest

final class TranscriptHighlightTests: XCTestCase {

    // MARK: - tokens

    func test_tokens_splitsOnNonAlphanumeric() {
        XCTAssertEqual(
            TranscriptHighlight.tokens(from: "open question follow-up"),
            ["open", "question", "follow", "up"]
        )
    }

    func test_tokens_lowercases() {
        XCTAssertEqual(
            TranscriptHighlight.tokens(from: "Decision OPEN"),
            ["decision", "open"]
        )
    }

    func test_tokens_dedupes() {
        XCTAssertEqual(
            TranscriptHighlight.tokens(from: "open OPEN open"),
            ["open"]
        )
    }

    func test_tokens_empty() {
        XCTAssertTrue(TranscriptHighlight.tokens(from: "").isEmpty)
        XCTAssertTrue(TranscriptHighlight.tokens(from: "   ").isEmpty)
        XCTAssertTrue(TranscriptHighlight.tokens(from: "---").isEmpty)
    }

    // MARK: - firstMatchIndex

    func test_firstMatchIndex_findsFirstHit() {
        let texts = [
            "Hello there",
            "Let's discuss the open question",
            "Move on to next item"
        ]
        XCTAssertEqual(
            TranscriptHighlight.firstMatchIndex(in: texts, query: "open"),
            1
        )
    }

    func test_firstMatchIndex_caseInsensitive() {
        let texts = ["Decision MADE today"]
        XCTAssertEqual(
            TranscriptHighlight.firstMatchIndex(in: texts, query: "made"),
            0
        )
    }

    func test_firstMatchIndex_anyTokenMatches() {
        // Multi-token query: any token hitting any element is a match.
        let texts = ["nothing here", "ship the build"]
        XCTAssertEqual(
            TranscriptHighlight.firstMatchIndex(in: texts, query: "deploy build"),
            1
        )
    }

    func test_firstMatchIndex_noMatch_returnsNil() {
        XCTAssertNil(
            TranscriptHighlight.firstMatchIndex(in: ["abc", "def"], query: "xyz")
        )
    }

    func test_firstMatchIndex_emptyQuery_returnsNil() {
        XCTAssertNil(
            TranscriptHighlight.firstMatchIndex(in: ["whatever"], query: "")
        )
    }

    func test_firstMatchIndex_emptyTexts_returnsNil() {
        XCTAssertNil(
            TranscriptHighlight.firstMatchIndex(in: [String](), query: "open")
        )
    }

    // MARK: - attributed

    func test_attributed_emptyQuery_returnsPlain() {
        let attr = TranscriptHighlight.attributed("hello world", query: nil)
        XCTAssertEqual(String(attr.characters), "hello world")
    }

    func test_attributed_preservesText() {
        let attr = TranscriptHighlight.attributed("hello open world", query: "open")
        XCTAssertEqual(String(attr.characters), "hello open world")
    }

    func test_attributed_appliesBackgroundOnMatch() {
        let attr = TranscriptHighlight.attributed("the open door", query: "open")
        // Find the "open" run and confirm it has a non-nil background.
        let runs = attr.runs
        let highlighted = runs.filter { run in
            run.backgroundColor != nil
        }
        XCTAssertFalse(highlighted.isEmpty, "Expected at least one highlighted run for matched token")
        // Concatenated highlighted text should be exactly the matched token.
        let highlightedText = highlighted
            .map { String(attr[$0.range].characters) }
            .joined()
        XCTAssertEqual(highlightedText.lowercased(), "open")
    }

    func test_attributed_highlightsMultipleOccurrences() {
        let attr = TranscriptHighlight.attributed("open and open again open", query: "open")
        let runs = attr.runs
        let highlightedCount = runs.filter { $0.backgroundColor != nil }.count
        XCTAssertEqual(highlightedCount, 3)
    }
}
