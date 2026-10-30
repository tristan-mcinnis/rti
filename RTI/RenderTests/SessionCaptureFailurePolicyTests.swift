import Foundation
import SwiftUI
import HouseDesign
import RTICore
import XCTest

final class SessionCaptureFailurePolicyTests: RenderProofTestCase {
    override func tearDown() async throws {
        let coordinator = SessionCoordinator.shared
        coordinator.retireLiveTranscriptionFailure(channel: "mic")
        coordinator.retireLiveTranscriptionFailure(channel: "system")
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    func testProviderFailureCallbackKeepsRecordingAndLegRecoveryIsIndependent() {
        let coordinator = SessionCoordinator.shared
        coordinator.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: nil)
        let before = coordinator.liveEntries.map(\.id)
        coordinator.receiveTranscriptionFailureForProof("Mic transcription unavailable. Audio is still recording.", isAuth: false, channel: "mic")
        coordinator.receiveTranscriptionFailureForProof("System transcription key rejected. Audio is still recording.", isAuth: true, channel: "system")
        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertEqual(coordinator.liveEntries.map(\.id), before)
        XCTAssertTrue(coordinator.canRetryLiveTranscription)
        coordinator.retireLiveTranscriptionFailure(channel: "mic")
        XCTAssertTrue(coordinator.lastErrorIsAuth, "Mic recovery must not hide system auth failure")
        XCTAssertTrue(coordinator.lastError?.contains("System transcription") == true)
        coordinator.retireLiveTranscriptionFailure(channel: "system")
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(coordinator.canRetryLiveTranscription)
    }

    func testProviderRecoveryDoesNotClearAnUnrelatedCaptureFault() {
        let coordinator = SessionCoordinator.shared
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: nil)
        coordinator.receiveTranscriptionFailureForProof("Provider failed", isAuth: false, channel: "mic")
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .recording, startedAt: nil, lastError: "Audio write failed")
        coordinator.retireLiveTranscriptionFailure(channel: "mic")
        XCTAssertEqual(coordinator.lastError, "Audio write failed")
    }

    func testArchiveFailureDoesNotPresentSavedState() {
        let coordinator = SessionCoordinator.shared
        coordinator.seedForRenderProof(entries: [], interim: nil, phase: .done, startedAt: nil)
        coordinator.reportArchiveSaveFailure()
        let status = OverlayShellStatus(phase: .done, processingStatus: coordinator.postProcessingStatus)
        XCTAssertNotEqual(status.word, "Session saved")
        XCTAssertTrue(status.word.contains("Save failed"))
        XCTAssertNotNil(coordinator.lastError)
    }

    func testTranscriptionRecoveryControlsInBothAppearances() throws {
        let coordinator = SessionCoordinator.shared
        coordinator.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: nil)
        coordinator.receiveTranscriptionFailureForProof("Live transcription disconnected. Audio is still recording.", isAuth: false, channel: "mic")
        try renderBothAppearances(
            name: "recording-transcription-recovery",
            size: WorkspaceLayout.minimumSize,
            view: WorkspaceView(model: WorkspaceModel(), modes: .inMemory())
        )
        try renderBothAppearances(
            name: "recording-transcript-retry",
            size: WorkspaceLayout.minimumSize,
            view: TranscriptTabView().background(House.ColorToken.surfaceRaised)
        )
    }

    func testTestsResolveLogsOutsideTheRealLogDirectory() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RTI")
        XCTAssertNotEqual(AppLog.logsDirectory.standardizedFileURL.path, real.standardizedFileURL.path)
        if let override = ProcessInfo.processInfo.environment["RTI_LOG_DIRECTORY"] {
            XCTAssertEqual(AppLog.logsDirectory.standardizedFileURL.path, URL(fileURLWithPath: override).standardizedFileURL.path)
        } else {
            XCTAssertTrue(AppLog.logsDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        }
    }
}
