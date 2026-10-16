import RTICore
import XCTest

/// Deterministic tests for the LLM admission policy: foreground never waits,
/// background waits and yields, releasing the same lease twice is a no-op, and
/// a cancelled waiter leaves the scheduler healthy.
///
/// No `Task.sleep` and no timing dependence: a background acquisition cannot
/// succeed while a foreground lease is live, so asserting "not yet acquired"
/// before release is exact regardless of scheduling.
final class LLMAdmissionTests: XCTestCase {
    /// A lock-guarded flag so the test can read what a child task recorded.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// Cooperatively let a child task run; returns as soon as the flag is set
    /// or after a bounded number of yields.
    @discardableResult
    private func yieldUntilSet(_ flag: Flag, attempts: Int = 200) async -> Bool {
        for _ in 0..<attempts {
            if flag.isSet { return true }
            await Task.yield()
        }
        return flag.isSet
    }

    private func isActive(_ controller: LLMAdmissionController) async -> Bool {
        await controller.foregroundActive
    }

    // MARK: - Foreground

    func testAcquireAndReleaseForeground() async {
        let controller = LLMAdmissionController()
        let lease = await controller.acquireForeground()
        let active = await isActive(controller)
        XCTAssertTrue(active)
        await controller.releaseForeground(lease)
        let after = await isActive(controller)
        XCTAssertFalse(after)
    }

    func testForegroundNeverWaitsWhileBackgroundIsHeld() async {
        let controller = LLMAdmissionController()
        // A background admission is outstanding (no foreground active).
        let background = await controller.acquireBackground()
        XCTAssertNotNil(background)
        // Foreground still admits immediately while that background slot is out.
        let foreground = await controller.acquireForeground()
        XCTAssertEqual(foreground.priority, LLMPriority.foreground)
        let active = await isActive(controller)
        XCTAssertTrue(active)
        await controller.releaseForeground(foreground)
        await controller.releaseBackground(background!.lease)
    }

    // MARK: - Background waits and resumes

    func testBackgroundCannotAcquireWhileForegroundHeld() async {
        let controller = LLMAdmissionController()
        let foreground = await controller.acquireForeground()
        let acquired = Flag()
        let task = Task { () -> Bool in
            guard let _ = await controller.acquireBackground() else { return false }
            acquired.set()
            return true
        }
        await yieldUntilSet(acquired)
        XCTAssertFalse(acquired.isSet, "background acquired while a foreground lease was held")

        await controller.releaseForeground(foreground)
        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertTrue(acquired.isSet)
    }

    // MARK: - Duplicate release is idempotent

    func testDuplicateForegroundReleaseDoesNotUnblockBackground() async {
        let controller = LLMAdmissionController()
        let first = await controller.acquireForeground()
        let second = await controller.acquireForeground()
        await controller.releaseForeground(first)
        // Releasing the SAME lease again must do nothing: `second` still holds.
        await controller.releaseForeground(first)

        let acquired = Flag()
        let task = Task { () -> Bool in
            guard let _ = await controller.acquireBackground() else { return false }
            acquired.set()
            return true
        }
        await yieldUntilSet(acquired)
        XCTAssertFalse(acquired.isSet, "a duplicate release wrongly freed a slot while another lease held")
        let stillActive = await isActive(controller)
        XCTAssertTrue(stillActive)

        await controller.releaseForeground(second)
        let result = await task.value
        XCTAssertTrue(result)
        XCTAssertTrue(acquired.isSet)
    }

    func testReleaseAfterLastLeaseIsIdempotentAndReusable() async {
        let controller = LLMAdmissionController()
        let lease = await controller.acquireForeground()
        await controller.releaseForeground(lease)
        // Extra release with no live lease must not underflow or wedge anything.
        await controller.releaseForeground(lease)
        let afterOverRelease = await isActive(controller)
        XCTAssertFalse(afterOverRelease)

        let background = await controller.acquireBackground()
        XCTAssertNotNil(background)
        await controller.releaseBackground(background!.lease)

        let foreground = await controller.acquireForeground()
        let active = await isActive(controller)
        XCTAssertTrue(active)
        await controller.releaseForeground(foreground)
        let done = await isActive(controller)
        XCTAssertFalse(done)
    }

    // MARK: - Foreground-arrival signal (preemption)

    func testForegroundArrivalFiresEpochWaiters() async {
        let controller = LLMAdmissionController()
        let epoch = await controller.currentForegroundEpoch
        let fired = Flag()
        let task = Task {
            await controller.waitForForegroundChange(after: epoch)
            fired.set()
        }
        await yieldUntilSet(fired)
        XCTAssertFalse(fired.isSet, "epoch waiter fired before any foreground arrived")

        let lease = await controller.acquireForeground()
        await task.value
        XCTAssertTrue(fired.isSet)
        await controller.releaseForeground(lease)
    }

    func testForegroundChangeAlreadyPassedReturnsImmediately() async {
        let controller = LLMAdmissionController()
        let before = await controller.currentForegroundEpoch
        let lease = await controller.acquireForeground()
        let after = await controller.currentForegroundEpoch
        XCTAssertNotEqual(before, after)
        // Waiting for a change after a stale epoch must not suspend.
        await controller.waitForForegroundChange(after: before)
        await controller.releaseForeground(lease)
    }

    // MARK: - Cancellation keeps the scheduler healthy

    func testCancelledQueuedBackgroundWaiterLeavesSchedulerHealthy() async {
        let controller = LLMAdmissionController()
        let foreground = await controller.acquireForeground()
        let started = Flag()
        let task = Task { () -> Bool in
            started.set()
            guard let _ = await controller.acquireBackground() else { return false }
            return true
        }
        await yieldUntilSet(started)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result, "a cancelled waiter must not be admitted")

        await controller.releaseForeground(foreground)
        // The scheduler still serves both priorities afterwards.
        let background = await controller.acquireBackground()
        XCTAssertNotNil(background)
        await controller.releaseBackground(background!.lease)

        let lease = await controller.acquireForeground()
        let active = await isActive(controller)
        XCTAssertTrue(active)
        await controller.releaseForeground(lease)
    }

    func testCancelledEpochWaiterDoesNotBlockForeground() async {
        let controller = LLMAdmissionController()
        let epoch = await controller.currentForegroundEpoch
        let task = Task { await controller.waitForForegroundChange(after: epoch) }
        await Task.yield()
        task.cancel()
        await task.value

        let lease = await controller.acquireForeground()
        await controller.releaseForeground(lease)
        let background = await controller.acquireBackground()
        XCTAssertNotNil(background)
        await controller.releaseBackground(background!.lease)
    }
}
