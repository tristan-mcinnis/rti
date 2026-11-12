import Foundation
import RTICore
import XCTest

@MainActor
final class ScreenshotPolicyTests: XCTestCase {
    func testManualDefaultAndGlobalOffOverrideProjectOptIn() throws {
        let suite = "rti.fixture.screenshot-policy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ScreenshotPolicy(defaults: defaults)
        XCTAssertEqual(policy.global, .manual)
        XCTAssertFalse(policy.allows(.automatic))
        policy.setOverride(.off, project: "Project A", callType: .research)
        policy.setOverride(.automatic, project: "Project B", callType: .research)
        XCTAssertEqual(policy.effective(project: "Project A", callType: .research), .off)
        XCTAssertEqual(policy.effective(project: "Project A", callType: .internal), .manual)
        XCTAssertEqual(ScreenshotPolicy(defaults: defaults).effective(project: "Project B", callType: .research), .automatic)
        policy.setGlobal(.off)
        XCTAssertEqual(policy.effective(project: "Project B", callType: .research), .off)
        XCTAssertThrowsError(try policy.permit(for: .manual))
        policy.setOverride(nil, project: "Project A", callType: .research)
        policy.setGlobal(.manual)
        XCTAssertNil(policy.override(project: "Project A", callType: .research))
        let permit = try policy.permit(for: .manual)
        policy.setGlobal(.off)
        policy.setGlobal(.manual)
        XCTAssertThrowsError(try policy.check(permit))
    }

    func testAutomaticPermitRequiresRecordingAndCannotResumeAfterPause() throws {
        let suite = "rti.fixture.recording-policy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ScreenshotPolicy(defaults: defaults)
        let session = SessionCoordinator.shared
        let start = Date()
        defer { session.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil) }
        policy.setGlobal(.automatic)
        session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: start)
        let permit = try policy.permit(for: .automatic)
        session.seedForRenderProof(entries: [], interim: nil, phase: .paused, startedAt: start)
        policy.automaticStateChanged()
        XCTAssertThrowsError(try policy.permit(for: .automatic))
        XCTAssertNoThrow(try policy.permit(for: .manual))
        session.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: start)
        XCTAssertThrowsError(try policy.check(permit))
        XCTAssertNoThrow(try policy.permit(for: .automatic))
    }

    func testOffRejectsEveryCaptureBeforeScreenAccess() async throws {
        let policy = ScreenshotPolicy.shared
        let prior = policy.global
        defer {
            policy.setGlobal(prior)
            LLMController.shared.clearPendingScreenContext()
        }
        policy.setGlobal(.off)
        ScreenshotManager.shared.captureAndAttach()
        XCTAssertEqual(LLMController.shared.screenCaptureStatus, "Screenshots are off.")
        ScreenshotManager.shared.captureFocusedWindowAndAttach()
        XCTAssertEqual(LLMController.shared.screenCaptureStatus, "Screenshots are off.")
        do {
            _ = try await ScreenshotManager.shared.captureAndDescribe(trigger: "tool")
            XCTFail("tool acquired a capture while Off")
        } catch ScreenshotError.disabled {}
        do {
            _ = try await ScreenshotManager.shared.captureActiveDisplayFrame(includeFrame: true)
            XCTFail("automatic capture outside its policy")
        } catch ScreenshotError.disabled {}
        XCTAssertNil(LLMController.shared.pendingScreenImage)
        XCTAssertNil(VisualContextTrail.shared.recentPromptContext())
        XCTAssertTrue(ScreenPrivacy.blockedBundleIDs.contains(RTIBuildProfile.stableID))
        XCTAssertTrue(ScreenPrivacy.blockedBundleIDs.contains(RTIBuildProfile.betaID))
    }
}
