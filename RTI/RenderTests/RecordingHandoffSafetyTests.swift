import Foundation
import RTICore
import XCTest

/// After a recording ends: a stop the user did not ask for stays visible, a
/// network fault in the transcript upgrade is retried and named as one, and
/// the folder still recording is never upgraded. Invented fixtures only; no
/// capture, socket or provider runs.
final class RecordingHandoffSafetyTests: RenderProofTestCase {
    override func tearDown() async throws {
        let coordinator = SessionCoordinator.shared
        coordinator.endUpgradePhaseForProof()
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    // MARK: F1: a recording that ended on its own never reads "Session saved"

    func testAnEarlyStopKeepsItsReasonPastTheRetirementAndIsNeverSessionSaved() async throws {
        let coordinator = SessionCoordinator.shared
        let saved = SessionCoordinator.stopErrorRetirementNs
        SessionCoordinator.stopErrorRetirementNs = 40_000_000
        defer { SessionCoordinator.stopErrorRetirementNs = saved }
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)

        let reason = "Meeting audio could not be saved for 30 seconds (invented disk fault), so recording stopped."
        coordinator.receiveRecordingFailureForProof(reason)
        XCTAssertEqual(coordinator.recordingStoppedEarly, reason)
        coordinator.scheduleStopErrorRetirement()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coordinator.lastError, reason, "the only sign the rest of the call is missing must not time out")

        let task = coordinator.runUpgradePhaseForProof(sessionId: "proof-\(UUID().uuidString)", llm: LLMController.shared) { nil }
        await task.value
        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertNotEqual(coordinator.postProcessingStatus, "Session saved")
        XCTAssertEqual(coordinator.postProcessingStatus, "Recording stopped early · see message")
        XCTAssertEqual(coordinator.lastError, reason)
    }

    func testAnOrdinaryStopStillReadsSessionSaved() async {
        let coordinator = SessionCoordinator.shared
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        let task = coordinator.runUpgradePhaseForProof(sessionId: "proof-\(UUID().uuidString)", llm: LLMController.shared) { nil }
        await task.value
        XCTAssertEqual(coordinator.postProcessingStatus, "Session saved")
        XCTAssertNil(coordinator.recordingStoppedEarly)
    }

    // MARK: NET-1: a network fault is retried and is not a disk fault

    func testNetworkAndProviderFaultsAreRetryableAndNotCalledWriteFailures() {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .networkConnectionLost, .timedOut] {
            let mapped = TranscriptUpgradeService.mapPipelineError(URLError(code))
            guard case TranscriptUpgradeError.networkFailed = mapped else {
                return XCTFail("\(code.rawValue) mapped to \(mapped)")
            }
            XCTAssertTrue(TranscriptUpgradeService.isRetryable(mapped))
            XCTAssertFalse(mapped.localizedDescription.contains("Couldn't write"), mapped.localizedDescription)
            XCTAssertTrue(mapped.localizedDescription.contains("internet connection"))
        }
        XCTAssertTrue(TranscriptUpgradeService.isRetryable(TranscriptUpgradeError.providerFailed("invented")))
        XCTAssertFalse(TranscriptUpgradeService.isRetryable(TranscriptUpgradeError.missingAudio))
        XCTAssertFalse(TranscriptUpgradeService.isRetryable(TranscriptUpgradeError.writeFailed("invented")))
        let disk = TranscriptUpgradeService.mapPipelineError(CocoaError(.fileWriteOutOfSpace))
        guard case TranscriptUpgradeError.writeFailed = disk else { return XCTFail("a disk fault is a write failure") }
    }

    func testTheAutomaticUpgradeRetriesOnceAfterTheWiFiDrops() async throws {
        var attempts = 0
        let result: String = try await RetryOnce.run(delay: .zero, shouldRetry: TranscriptUpgradeService.isRetryable) {
            attempts += 1
            if attempts == 1 {
                throw TranscriptUpgradeService.mapPipelineError(URLError(.notConnectedToInternet))
            }
            return "upgraded"
        }
        XCTAssertEqual(result, "upgraded")
        XCTAssertEqual(attempts, 2)
    }

    // MARK: NET-2: the folder still recording is never upgraded

    func testTheLiveRecordingFolderIsRefusedAndNothingIsWritten() async throws {
        let coordinator = SessionCoordinator.shared
        let startedAt = Date(timeIntervalSince1970: 1_780_000_123)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rti-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("RIFF invented growing audio".utf8).write(to: folder.appendingPathComponent("audio-mic.wav"))

        for phase in [SessionCoordinator.Phase.recording, .paused, .finishing] {
            coordinator.seedForRenderProof(entries: [], interim: nil, phase: phase, startedAt: startedAt.addingTimeInterval(0.4))
            do {
                _ = try await TranscriptUpgradeService.upgrade(sessionDirectory: folder, startedAt: startedAt) { _ in }
                XCTFail("the folder still recording was upgraded in \(phase)")
            } catch TranscriptUpgradeError.stillRecording {
            } catch {
                XCTFail("\(phase): \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["audio-mic.wav"])
        XCTAssertTrue(TranscriptUpgradeError.stillRecording.localizedDescription.contains("Stop the recording"))
    }

    func testSessionsHidesUpgradeOnTheLiveRowOnly() async throws {
        let model = SessionsWindowModel(dependencies: .init(contentSearch: nil, now: { Date() }))
        await model.reload()
        var row = try XCTUnwrap(model.rows.first { $0.session.date != nil })
        row.hasRetainedAudio = true
        let coordinator = SessionCoordinator.shared

        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: row.session.date)
        XCTAssertFalse(model.actions(for: row).contains(.upgradeTranscript), "the live row must not offer Upgrade")
        XCTAssertFalse(model.actions(for: row).contains(.trash))

        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: row.session.date?.addingTimeInterval(3600))
        XCTAssertTrue(model.actions(for: row).contains(.upgradeTranscript), "another session recording does not block this one")

        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .done, startedAt: row.session.date)
        XCTAssertTrue(model.actions(for: row).contains(.upgradeTranscript), "after Stop the row can be upgraded")
    }
}
