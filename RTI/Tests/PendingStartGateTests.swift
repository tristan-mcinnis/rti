import XCTest
import RTICore

/// A stop pressed while the mic permission prompt is open must cancel the
/// pending start. Granting afterwards must not start a session.
final class PendingStartGateTests: XCTestCase {

    /// Mirrors `SessionCoordinator.startSession` and its permission callback.
    private final class FakeCoordinator {
        var gate = PendingStartGate()
        var launches = 0
        var answer: ((Bool) -> Void)?

        func start() {
            guard let token = gate.begin() else { return }
            answer = { [self] granted in
                guard gate.resolve(token), granted else { return }
                launches += 1
            }
        }

        func stop() { gate.cancel() }
    }

    func testStopWhilePermissionPendingMeansNoSessionAfterGrant() {
        let app = FakeCoordinator()
        app.start()
        XCTAssertTrue(app.gate.isPending)
        app.stop()
        app.answer?(true)
        XCTAssertEqual(app.launches, 0)
        XCTAssertFalse(app.gate.isPending)
    }

    func testGrantWithoutStopStartsOnce() {
        let app = FakeCoordinator()
        app.start()
        app.start()   // second press while pending is ignored by begin()
        app.answer?(true)
        XCTAssertEqual(app.launches, 1)
        XCTAssertFalse(app.gate.isPending)
    }

    func testStaleAnswerFromCancelledStartIsIgnoredAfterRestart() {
        let app = FakeCoordinator()
        app.start()
        let stale = app.answer
        app.stop()
        app.start()
        stale?(true)
        XCTAssertEqual(app.launches, 0)
        XCTAssertTrue(app.gate.isPending)
        app.answer?(true)
        XCTAssertEqual(app.launches, 1)
    }

    func testCancelWithNothingPendingReturnsFalse() {
        var gate = PendingStartGate()
        XCTAssertFalse(gate.cancel())
    }
}
