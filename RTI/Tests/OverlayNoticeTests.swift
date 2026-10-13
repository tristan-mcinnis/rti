import RTICore
import XCTest

final class OverlayNoticeTests: XCTestCase {
    func testMuteBannerOnlyWhileRecordingAndMuted() {
        XCTAssertTrue(MuteBannerRule.shows(isRunning: true, micMuted: true))
        XCTAssertFalse(MuteBannerRule.shows(isRunning: true, micMuted: false))
        XCTAssertFalse(MuteBannerRule.shows(isRunning: false, micMuted: true))
    }

    func testHotkeyNoticeRule() {
        XCTAssertNil(HotkeyNoticeRule.message(failedTitles: [], dismissedSignature: ""))
        let msg = HotkeyNoticeRule.message(failedTitles: ["Show RTI"], dismissedSignature: "")
        XCTAssertTrue(msg?.contains("Show RTI") == true)
        let sig = HotkeyNoticeRule.signature(["Show RTI"])
        XCTAssertNil(HotkeyNoticeRule.message(failedTitles: ["Show RTI"], dismissedSignature: sig))
        XCTAssertNotNil(HotkeyNoticeRule.message(failedTitles: ["Show RTI", "Start"], dismissedSignature: sig))
    }
}
