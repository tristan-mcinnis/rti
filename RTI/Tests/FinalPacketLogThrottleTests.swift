import RTICore
import XCTest

/// One leg logs its first packet with final tokens, then every 100th.
final class FinalPacketLogThrottleTests: XCTestCase {
    func testLogsTheFirstThenEveryHundredth() {
        var throttle = FinalPacketLogThrottle()
        var logged: [Int] = []
        for packet in 1 ... 250 where throttle.record() {
            logged.append(packet)
        }
        XCTAssertEqual(logged, [1, 100, 200])
        XCTAssertEqual(throttle.count, 250)
    }

    func testEachLegCountsOnItsOwn() {
        var mic = FinalPacketLogThrottle()
        var system = FinalPacketLogThrottle()
        XCTAssertTrue(mic.record())
        for _ in 2 ... 99 {
            XCTAssertFalse(mic.record())
        }
        XCTAssertTrue(system.record(), "the other leg still logs its own first packet")
        XCTAssertTrue(mic.record(), "the mic leg logs its 100th")
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(mic.count, 100)
    }
}
