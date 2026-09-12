import XCTest
import RTICore

/// Pins the menu-bar status item's tick policy. The 1 Hz timer used to run for
/// the life of the app; it must now exist only while a session is actually
/// recording, and the elapsed readout must stay correct.
final class MenuStatusTickTests: XCTestCase {

    private let allPhases: [SessionPhase] = [.idle, .recording, .paused, .finishing, .summarizing, .done]

    /// Idle means no repeating timer — the regression this test exists for.
    func testOnlyRecordingNeedsARepeatingTimer() {
        for phase in allPhases {
            XCTAssertEqual(
                MenuStatusTick.needsRepeatingTimer(phase),
                phase == .recording,
                "\(phase) disagrees on needing a repeating timer"
            )
        }
    }

    func testIdleAndFinishedPhasesNeverTick() {
        for phase in [SessionPhase.idle, .paused, .finishing, .summarizing, .done] {
            XCTAssertFalse(MenuStatusTick.needsRepeatingTimer(phase), "\(phase) still schedules a timer")
        }
    }

    /// The readout's visibility rule is unchanged by the timer work: a paused
    /// or finishing session still shows its (frozen) time.
    func testElapsedReadoutVisibilityIsUnchanged() {
        XCTAssertTrue(MenuStatusTick.showsElapsed(.recording))
        XCTAssertTrue(MenuStatusTick.showsElapsed(.paused))
        XCTAssertTrue(MenuStatusTick.showsElapsed(.finishing))
        XCTAssertFalse(MenuStatusTick.showsElapsed(.idle))
        XCTAssertFalse(MenuStatusTick.showsElapsed(.summarizing))
        XCTAssertFalse(MenuStatusTick.showsElapsed(.done))
    }

    /// A phase that ticks must be a phase that shows something to tick.
    func testEveryTickingPhaseShowsTheReadout() {
        for phase in allPhases where MenuStatusTick.needsRepeatingTimer(phase) {
            XCTAssertTrue(MenuStatusTick.showsElapsed(phase), "\(phase) ticks without showing a readout")
        }
    }

    /// Non-zero tolerance is what lets the OS coalesce the wakeup; keeping it
    /// under half a second keeps the seconds digit visually honest.
    func testToleranceAllowsCoalescingWithoutVisibleDrift() {
        XCTAssertEqual(MenuStatusTick.interval, 1)
        XCTAssertGreaterThan(MenuStatusTick.tolerance, 0)
        XCTAssertLessThanOrEqual(MenuStatusTick.tolerance, MenuStatusTick.interval / 4)
    }

    /// The readout the timer drives.
    func testElapsedReadoutFormatting() {
        XCTAssertEqual(TimeFormat.elapsed(0), "0:00")
        XCTAssertEqual(TimeFormat.elapsed(187), "3:07")
        XCTAssertEqual(TimeFormat.elapsed(59.9), "0:59")
        XCTAssertEqual(TimeFormat.elapsed(3661), "1:01:01")
    }
}
