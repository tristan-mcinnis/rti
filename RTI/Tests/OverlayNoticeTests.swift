import RTICore
import XCTest

final class OverlayNoticeTests: XCTestCase {
    func testMuteBannerOnlyWhileRecordingAndMuted() {
        let live = MicControl().reduced(.sessionStarted)
        let muted = live.reduced(.toggleMute)
        let listening = MicControl().reduced(.setPreset(.listeningOnly)).reduced(.sessionStarted)
        XCTAssertTrue(MuteBannerRule.shows(isRunning: true, mic: muted))
        XCTAssertFalse(MuteBannerRule.shows(isRunning: true, mic: listening))
        XCTAssertFalse(MuteBannerRule.shows(isRunning: true, mic: live))
        XCTAssertFalse(MuteBannerRule.shows(isRunning: false, mic: muted))
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
