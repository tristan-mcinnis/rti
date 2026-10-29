import XCTest

final class CrashNoticeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_noCrashLog_doesNotShow() {
        XCTAssertFalse(CrashNotice.shouldShow(crashLogModified: nil, lastAcknowledged: nil))
        XCTAssertFalse(CrashNotice.shouldShow(crashLogModified: nil, lastAcknowledged: t0))
    }

    func test_crashNeverAcknowledged_shows() {
        XCTAssertTrue(CrashNotice.shouldShow(crashLogModified: t0, lastAcknowledged: nil))
    }

    func test_crashNewerThanAcknowledged_shows() {
        XCTAssertTrue(CrashNotice.shouldShow(crashLogModified: t0.addingTimeInterval(5), lastAcknowledged: t0))
    }

    func test_crashAtOrBeforeAcknowledged_doesNotShow() {
        XCTAssertFalse(CrashNotice.shouldShow(crashLogModified: t0, lastAcknowledged: t0))
        XCTAssertFalse(CrashNotice.shouldShow(crashLogModified: t0.addingTimeInterval(-5), lastAcknowledged: t0))
    }
}
