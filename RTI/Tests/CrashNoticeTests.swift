import RTICore
import XCTest

final class CrashNoticeTests: XCTestCase {
    func test_cleanExit_doesNotShow() {
        XCTAssertFalse(CrashNoticeDecision.shouldShow(previousExitWasClean: true, onboardingNeeded: false))
    }

    func test_uncleanExit_shows() {
        XCTAssertTrue(CrashNoticeDecision.shouldShow(previousExitWasClean: false, onboardingNeeded: false))
    }

    func test_firstRun_doesNotShow() {
        XCTAssertFalse(CrashNoticeDecision.shouldShow(previousExitWasClean: false, onboardingNeeded: true))
    }
}
