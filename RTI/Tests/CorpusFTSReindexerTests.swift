import XCTest

final class CorpusFTSReindexerTests: XCTestCase {

    func test_splitBody_findsTranscriptHeading() {
        let body = "## Summary\nGood\n\n## Transcript\n[self 0:00] hi"
        let (summary, transcript) = CorpusFTSReindexer.splitBody(body)
        XCTAssertTrue(summary.contains("Good"))
        XCTAssertTrue(transcript.contains("[self 0:00] hi"))
    }

    func test_splitBody_noTranscript_returnsAllAsSummary() {
        let (summary, transcript) = CorpusFTSReindexer.splitBody("just summary here")
        XCTAssertEqual(summary, "just summary here")
        XCTAssertEqual(transcript, "")
    }

    func test_splitBody_emptySummary() {
        let (summary, transcript) = CorpusFTSReindexer.splitBody("## Transcript\n[self 0:00] hi")
        XCTAssertEqual(summary, "")
        XCTAssertTrue(transcript.contains("[self 0:00] hi"))
    }
}
