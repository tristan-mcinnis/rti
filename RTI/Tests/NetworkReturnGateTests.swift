import RTICore
import XCTest

/// NET-1: queued transcript upgrades run again when the network returns,
/// not only at the next launch. The gate decides what counts as a return.
final class NetworkReturnGateTests: XCTestCase {
    func testOnlyAChangeFromOfflineToOnlineIsAReturn() {
        var gate = NetworkReturnGate()
        XCTAssertFalse(gate.update(available: true), "the first report at launch is not a return")
        XCTAssertFalse(gate.update(available: true))
        XCTAssertFalse(gate.update(available: false))
        XCTAssertFalse(gate.update(available: false))
        XCTAssertTrue(gate.update(available: true), "Wi-Fi back after an outage")
        XCTAssertFalse(gate.update(available: true))
    }

    func testStartingOfflineThenComingOnlineIsAReturn() {
        var gate = NetworkReturnGate()
        XCTAssertFalse(gate.update(available: false))
        XCTAssertTrue(gate.update(available: true))
    }
}
