import RTICore
import XCTest

final class AnswerCleanupTests: XCTestCase {
    func testPinyinStaysOnlyUnderAChineseLine() {
        let text = """
        - Ask about the lid.

        **Suggested question for the moderator** 盖子好拧吗？

        **Pinyin** gài zi hǎo nǐng ma?

        **Pinyin** nǐ huì zěn me cún?
        """
        let cleaned = AnswerCleanup.dropOrphanPinyin(text)
        XCTAssertTrue(cleaned.contains("gài zi hǎo nǐng ma?"))
        XCTAssertFalse(cleaned.contains("nǐ huì zěn me cún?"), "a pinyin line under another pinyin line has no Chinese above it")
        XCTAssertEqual(AnswerCleanup.dropOrphanPinyin("**Pinyin** orphan"), "")
        XCTAssertEqual(AnswerCleanup.dropOrphanPinyin("Plain answer."), "Plain answer.")
    }
}
