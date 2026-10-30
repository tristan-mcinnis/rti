import AppKit
import HouseDesign
import RTICore
import SwiftUI
import XCTest

final class WorkspaceVisibilityRegressionTests: RenderProofTestCase {
    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
    }

    func testLeavingLiveSuspendsTranscriptLayoutButKeepsRecordingState() {
        let session = SessionCoordinator.shared
        session.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: nil)
        let model = WorkspaceModel(settings: SettingsNavigation(pane: .about))
        let host = NSHostingView(rootView: WorkspaceView(model: model, modes: .inMemory()))
        host.frame = NSRect(origin: .zero, size: WorkspaceLayout.standardSize)
        defer {
            NotificationCenter.default.post(name: .rtiSelectTab, object: "assist")
            settle(host)
            session.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        }
        settle(host)
        NotificationCenter.default.post(name: .rtiSelectTab, object: "transcript")
        settle(host)
        assertPresentation(active: true, session: session)
        for page in [WorkspaceModel.Page.sessions, .chats, .settings] {
            model.select(page)
            settle(host)
            assertPresentation(active: false, session: session)
            XCTAssertEqual(session.phase, .recording)
            model.select(.live)
            settle(host)
            assertPresentation(active: true, session: session)
        }
        model.setWindowVisible(false)
        settle(host)
        assertPresentation(active: false, session: session)
        XCTAssertEqual(session.phase, .recording)
        model.setWindowVisible(true)
        settle(host)
        assertPresentation(active: true, session: session)
    }

    func testLibraryVisibilityFollowsWindowAcrossCloseAndReopen() {
        let model = WorkspaceModel()
        model.select(.sessions)
        XCTAssertTrue(model.sessions.isWindowVisible)
        model.setWindowVisible(false)
        XCTAssertFalse(model.sessions.isWindowVisible)
        model.select(.chats)
        XCTAssertFalse(model.sessions.isWindowVisible)
        model.setWindowVisible(true)
        XCTAssertTrue(model.sessions.isWindowVisible)
        model.select(.live)
        XCTAssertFalse(model.sessions.isWindowVisible)
        XCTAssertTrue(model.isLivePageActive)
    }

    private func assertPresentation(active: Bool, session: SessionCoordinator, file: StaticString = #filePath, line: UInt = #line) {
        let revision = session.transcriptDisplayRevision
        session.refreshTranscriptPresentation()
        if active { XCTAssertGreaterThan(session.transcriptDisplayRevision, revision, file: file, line: line) }
        else { XCTAssertEqual(session.transcriptDisplayRevision, revision, file: file, line: line) }
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
