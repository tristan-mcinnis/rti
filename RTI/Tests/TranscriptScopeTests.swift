import RTICore
import XCTest

final class TranscriptScopeTests: XCTestCase {
    func testWholeCallQuestionsReadTheWholeCall() {
        for question in ["What are the themes?", "Summarize so far", "Any tensions across the group?", "目前为止的主题是什么？", "总结一下"] {
            XCTAssertTrue(TranscriptScope.wantsWholeCall(question), question)
        }
        for question in ["What did she just say?", "How do I ask about price?", "刚才她说什么？"] {
            XCTAssertFalse(TranscriptScope.wantsWholeCall(question), question)
        }
    }

    func testALongTranscriptKeepsItsNewestLinesWhole() {
        let lines = (0 ..< 100).map { "[\($0)] line \($0)" }.joined(separator: "\n")
        let fitted = TranscriptScope.fitted(lines, cap: 200)
        XCTAssertTrue(fitted.hasPrefix("[Earlier talk left out"))
        XCTAssertTrue(fitted.hasSuffix("[99] line 99"))
        XCTAssertFalse(fitted.contains("\n line"), "the cut lands at a line start")
        XCTAssertEqual(TranscriptScope.fitted("short", cap: 200), "short")
    }
}
