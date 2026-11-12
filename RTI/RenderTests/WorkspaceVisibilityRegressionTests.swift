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

    func testRegularWindowSharingAndExplicitPreferenceSurviveReopen() throws {
        let suite = "fixture.window-sharing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let workspace = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let onboarding = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        for window in [workspace, onboarding] {
            window.configureRTITitledWindow(defaults: defaults)
            XCTAssertEqual(window.level, .normal)
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.sharingType, .readOnly)
            XCTAssertFalse(window.isVisible)
        }
        XCTAssertNil(defaults.object(forKey: OverlayAppearanceDefaults.invisibilityKey))
        defaults.set(true, forKey: OverlayAppearanceDefaults.invisibilityKey)
        workspace.level = .floating
        workspace.applyRTISharingPolicy(defaults: defaults)
        XCTAssertEqual(workspace.sharingType, .none)
        XCTAssertEqual(workspace.level, .floating)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        onboarding.configureRTITitledWindow(defaults: reopened)
        XCTAssertEqual(onboarding.sharingType, .none)
        reopened.set(false, forKey: OverlayAppearanceDefaults.invisibilityKey)
        workspace.applyRTISharingPolicy(defaults: reopened)
        XCTAssertEqual(workspace.sharingType, .readOnly)
        XCTAssertFalse(OverlayAppearanceDefaults.hidesWindowsFromScreenCapture(in: reopened))
    }

    func testFrameRestoresOnLeftDisplayAndClampsAfterDisconnect() {
        let main = NSRect(x: 0, y: 0, width: 1512, height: 949)
        let left = NSRect(x: -3440, y: -201, width: 3440, height: 1410)
        let descriptor = "-3385 -161 805 550 -3440 -201 3440 1410"
        func restore(_ frames: [NSRect], on screen: NSRect, saved: String?) -> NSRect {
            WorkspaceFramePlacement.restore(saved, legacy: nil, screenFrames: frames, preferred: screen,
                standard: WorkspaceLayout.standardSize, minimum: WorkspaceLayout.minimumSize)
        }
        XCTAssertEqual(restore([main, left], on: main, saved: descriptor), NSRect(x: -3385, y: -161, width: 805, height: 550))
        let afterDisconnect = restore([main], on: main, saved: descriptor)
        XCTAssertTrue(main.contains(afterDisconnect))
        XCTAssertEqual(afterDisconnect.size, NSSize(width: 805, height: 550))
        let small = NSRect(x: -800, y: -600, width: 800, height: 600)
        XCTAssertTrue(small.contains(restore([small], on: small, saved: nil)))
    }

    func testHeaderDoubleClickRespectsNativeAction() {
        final class WindowSpy: NSWindow {
            var zooms = 0
            var minimizes = 0
            override func performZoom(_ sender: Any?) { zooms += 1 }
            override func performMiniaturize(_ sender: Any?) { minimizes += 1 }
        }
        let window = WindowSpy(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        WindowDragArea.doubleClick(window, preference: "None")
        XCTAssertEqual(window.zooms + window.minimizes, 0)
        WindowDragArea.doubleClick(window, preference: "Minimize")
        WindowDragArea.doubleClick(window, preference: "Maximize")
        XCTAssertEqual(window.zooms, 1)
        XCTAssertEqual(window.minimizes, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testLeavingLiveSuspendsTranscriptLayoutButKeepsRecordingState() {
        let session = SessionCoordinator.shared
        session.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording, startedAt: nil)
        let model = WorkspaceModel(settings: SettingsNavigation(pane: .about))
        let host = NSHostingView(rootView: WorkspaceView(model: model, callTypes: .inMemory()))
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
