@testable import RTICore
import XCTest

final class MicRebindPacerTests: XCTestCase {
    func testABurstMergesAndRTIsOwnEchoIsDropped() {
        var pacer = MicRebindPacer()
        XCTAssertEqual(pacer.delay(now: 100), MicRebindPacer.mergeDelay)
        pacer.didRebind(at: 100.3)
        // The fresh engine's own change, 150 ms later: dropped.
        XCTAssertNil(pacer.delay(now: 100.45))
        XCTAssertNil(pacer.delay(now: 101.2))
        XCTAssertEqual(pacer.delay(now: 101.4), MicRebindPacer.mergeDelay)
    }

    func testRepeatedRebindsBackOff() {
        var pacer = MicRebindPacer()
        for time in [0.0, 2, 4] {
            pacer.didRebind(at: time)
        }
        XCTAssertEqual(pacer.delay(now: 6), MicRebindPacer.backoff)
        // Once the window has passed, a change rebinds quickly again.
        XCTAssertEqual(pacer.delay(now: 15), MicRebindPacer.mergeDelay)
    }
}
