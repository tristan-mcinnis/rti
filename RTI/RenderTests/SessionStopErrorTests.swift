import RTICore
import XCTest

/// A session's failure notice belongs to that session.
///
/// It used to be cleared in exactly one place, the start of the next session,
/// so a microphone outage that ended an evening recording was still painted
/// above the composer the next morning, reading "206s ago" as though the mic
/// were dead right then, and pointing at Privacy settings for nothing
/// (2026-09-23). The notice is now retired once the session stops, except for
/// an auth or billing failure, whose message is itself the fix.
///
/// This lives beside the render proofs because `RTITests` deliberately compiles
/// no app sources: it has no host and cannot see `SessionCoordinator`.
@MainActor
final class SessionStopErrorTests: XCTestCase {
    private let outage = "Microphone audio stopped (206s ago) — the input device may have "
        + "disconnected or RTI lost mic access. Restart the session, or check Settings → Privacy → Microphone."

    override func tearDown() async throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: [], interim: nil, phase: .idle, startedAt: nil
        )
        try await super.tearDown()
    }

    /// The seam is `scheduleStopErrorRetirement` itself: `stopSession` needs a
    /// running session, which a unit test cannot stand up. The one-line wiring
    /// from `stopSession` to it is read, not tested.
    func test_aStoppedSessionsFailure_isRetiredRatherThanHauntingTheNextMorning() async throws {
        let coordinator = SessionCoordinator.shared
        let savedRetention = SessionCoordinator.stopErrorRetirementNs
        SessionCoordinator.stopErrorRetirementNs = 40_000_000
        defer { SessionCoordinator.stopErrorRetirementNs = savedRetention }

        coordinator.seedForRenderProof(
            entries: [], interim: nil, phase: .idle, startedAt: nil,
            lastError: outage, lastErrorIsAuth: false
        )
        coordinator.scheduleStopErrorRetirement()
        XCTAssertEqual(
            coordinator.lastError, outage,
            "the reason a session ended is the only place it is stated, so it is kept to be read"
        )

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(coordinator.lastError, "it must not still be there the next morning")
    }

    func test_anAuthFailure_survivesTheRetentionBecauseItsMessageCarriesTheFix() async throws {
        let coordinator = SessionCoordinator.shared
        let savedRetention = SessionCoordinator.stopErrorRetirementNs
        SessionCoordinator.stopErrorRetirementNs = 40_000_000
        defer { SessionCoordinator.stopErrorRetirementNs = savedRetention }

        coordinator.seedForRenderProof(
            entries: [], interim: nil, phase: .idle, startedAt: nil,
            lastError: "Soniox rejected the API key.", lastErrorIsAuth: true
        )
        coordinator.scheduleStopErrorRetirement()

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            coordinator.lastError, "Soniox rejected the API key.",
            "the error line's Open Settings affordance depends on this still being here"
        )
        XCTAssertTrue(coordinator.lastErrorIsAuth)
    }
}
