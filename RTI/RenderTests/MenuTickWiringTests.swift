import XCTest
import RTICore

/// Proves the wiring, not just the policy: the status item's 1 Hz timer is
/// owned by the recording phase. RTI idles all day, and this timer used to run
/// from launch to quit — ~86,400 main-thread wakeups a day to redraw a glyph
/// that had not changed. Lives in the render bundle because that is the target
/// which compiles the whole app module (`MenuCoordinator` is AppKit).
///
/// No status bar is touched: `install()` is never called, so `statusItem` stays
/// nil and `refreshTitle()` writes into an absent button. The timer decision is
/// the part under test.
@MainActor
final class MenuTickWiringTests: XCTestCase {

    private func seed(_ phase: SessionCoordinator.Phase, startedAt: Date? = nil) {
        SessionCoordinator.shared.seedForRenderProof(
            entries: [], interim: nil, phase: phase, startedAt: startedAt
        )
    }

    /// Leave the shared coordinator as we found it, and never leave a live
    /// timer on the test runloop.
    private func reset(_ menu: MenuCoordinator) {
        seed(.idle)
        menu.refreshTitle()
    }

    /// App launch with no session: no repeating timer at all.
    func testIdleHoldsNoRepeatingTimer() {
        let menu = MenuCoordinator()
        seed(.idle)
        menu.refreshTitle()
        XCTAssertNil(menu.elapsedTimer, "idle RTI scheduled a repeating timer")
    }

    /// A recording session always has one, and it carries the coalescing
    /// tolerance rather than demanding an exact wakeup.
    func testRecordingSchedulesOneToleratedTimer() throws {
        let menu = MenuCoordinator()
        seed(.recording, startedAt: Date())
        menu.refreshTitle()

        let timer = try XCTUnwrap(menu.elapsedTimer, "a recording session has no timer")
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.timeInterval, MenuStatusTick.interval, accuracy: 0.001)
        XCTAssertEqual(timer.tolerance, MenuStatusTick.tolerance, accuracy: 0.001)

        // Re-entrant refreshes (the timer calls refreshTitle itself) must keep
        // the same timer, never stack a second one.
        menu.refreshTitle()
        menu.refreshTitle()
        XCTAssertTrue(menu.elapsedTimer === timer, "refreshing while recording rescheduled the timer")

        reset(menu)
        XCTAssertNil(menu.elapsedTimer)
        XCTAssertFalse(timer.isValid, "the timer was dropped without being invalidated")
    }

    /// Pause, the post-stop flush, the summary pass and the finished state all
    /// show a frozen readout — none of them needs a tick.
    func testEveryNonRecordingPhaseEndsWithNoTimer() {
        let menu = MenuCoordinator()
        for phase in [SessionCoordinator.Phase.paused, .finishing, .summarizing, .done, .idle] {
            seed(.recording, startedAt: Date())
            menu.refreshTitle()
            XCTAssertNotNil(menu.elapsedTimer, "recording did not start a timer before \(phase)")

            seed(phase, startedAt: Date())
            menu.refreshTitle()
            XCTAssertNil(menu.elapsedTimer, "\(phase) left a repeating timer running")
        }
        reset(menu)
    }

    /// Starting a session after any other phase always starts a tick.
    func testStartingASessionAlwaysStartsATick() {
        let menu = MenuCoordinator()
        for phase in [SessionCoordinator.Phase.idle, .paused, .finishing, .summarizing, .done] {
            seed(phase, startedAt: Date())
            menu.refreshTitle()

            seed(.recording, startedAt: Date())
            menu.refreshTitle()
            XCTAssertNotNil(menu.elapsedTimer, "recording after \(phase) did not start a tick")
        }
        reset(menu)
    }

    /// The readout the tick drives is still the captured-time elapsed.
    func testElapsedReadoutIsStillCorrect() {
        let menu = MenuCoordinator()
        let now = Date()
        seed(.recording, startedAt: now.addingTimeInterval(-187))
        menu.refreshTitle()

        XCTAssertEqual(TimeFormat.elapsed(SessionCoordinator.shared.elapsed(at: now)), "3:07")
        reset(menu)
    }
}
