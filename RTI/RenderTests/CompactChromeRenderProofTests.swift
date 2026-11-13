import AppKit
import HouseChatCore
import HouseDesign
import RTICore
import SwiftUI
import XCTest

/// Invented chat content and capture states at both supported window widths.
/// These proofs isolate the header and reader chrome from navigation work.
final class CompactChromeRenderProofTests: RenderProofTestCase {
    override func tearDown() async throws {
        SessionCoordinator.shared.seedMicForRenderProof(MicControl())
        MeetingContextStore.shared.resetAfterSession()
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        try await super.tearDown()
    }

    func testHeaderKeepsCaptureStateAtCompactAndStandardWidths() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        for (suffix, width) in headerWidths {
            try renderBothAppearances(
                name: "compact-chrome-header-\(suffix)",
                size: CGSize(width: width, height: House.Control.composer * 3),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: .init(phase: .idle))
                    OverlayShellHeader(status: .init(phase: .recording))
                    OverlayShellHeader(status: .init(phase: .paused))
                }
                .background(House.ColorToken.surface)
            )
        }
    }

    /// The workspace header, idle and recording, at the standard 860 and
    /// the minimum 720 width, light and dark. Each control has one home:
    /// no assistant-options button, no project chip, no overflow popover;
    /// the mic stays in the row at 720, and so does the title (its column
    /// is fixed, so the routes do not move on Record).
    /// PNG `compact-chrome-workspace-header-*`.
    func testWorkspaceHeaderIdleAndRecordingAtWideAndNarrow() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        let model = WorkspaceModel()
        let widths: [(String, CGFloat)] = [
            ("wide", WorkspaceLayout.standardSize.width),
            ("narrow", WorkspaceLayout.minimumSize.width)
        ]
        for (suffix, width) in widths {
            try renderBothAppearances(
                name: "compact-chrome-workspace-header-\(suffix)",
                size: CGSize(width: width, height: House.Control.composer * 2),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: .init(phase: .idle), fill: House.ColorToken.surfaceSunken, workspace: model)
                    OverlayShellHeader(status: .init(phase: .recording), fill: House.ColorToken.surfaceSunken, workspace: model)
                }
            )
        }
        // At 720 the recording row's controls (routes, mic, eye, pause,
        // record with its clock) leave the title its whole column; Listening
        // only folds into the title there, so it costs no width.
        let recording = OverlayShellStatus(phase: .recording)
        let controls = NSHostingView(rootView: HStack(spacing: House.Spacing.xs) {
            Color.clear.frame(width: OverlayShellHeader.workspaceTitleWidth)
            WorkspaceRouteSegments(model: model)
            OverlayMicControl()
            OverlayVisualContextButton(isLive: true)
            OverlaySessionAuxButton(phase: .recording)
            OverlayRecordButton(status: recording, showsTitle: true, showsKeys: false)
        }.fixedSize())
        let room = WorkspaceLayout.minimumSize.width - HouseChatMetrics.trafficLightInset - House.Spacing.lg
        XCTAssertLessThanOrEqual(controls.fittingSize.width, room,
                                 "Header controls and title (\(controls.fittingSize.width) pt) overflow \(room) pt at 720")
        XCTAssertTrue(OverlayShellHeader.foldsListeningOnly(width: WorkspaceLayout.minimumSize.width, inWorkspace: true))
        XCTAssertFalse(OverlayShellHeader.foldsListeningOnly(width: WorkspaceLayout.standardSize.width, inWorkspace: true))
        XCTAssertFalse(OverlayShellHeader.foldsListeningOnly(width: WorkspaceLayout.minimumSize.width, inWorkspace: false))
    }

    /// The narrowest row: 720 pt, recording in Listening only beside the
    /// clock, with a calendar event and a project picked, light and dark.
    /// At 720 Listening only is the title's state line (no chip), so the
    /// title keeps its column; at 860 it is a chip. Nothing clips.
    /// PNG `compact-chrome-workspace-header-listening-narrow-*` (and `-wide-`).
    func testWorkspaceHeaderListeningOnlyAtNarrowestWidth() throws {
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        var mic = MicControl()
        mic.reduce(.setPreset(.listeningOnly))
        mic.reduce(.sessionStarted)
        SessionCoordinator.shared.seedMicForRenderProof(mic)
        XCTAssertTrue(SessionCoordinator.shared.isListeningOnly)
        let project = VaultItem(id: "projects/northwind", name: "Northwind app",
                                url: URL(fileURLWithPath: "/tmp/northwind"), isProject: true)
        MeetingContextStore.shared.workstreamItem = project
        MeetingContextStore.shared.workstreamName = project.name
        MeetingContextStore.shared.selectCalendarMeeting(CalendarMeeting(
            id: "fixture-event", title: "Onboarding scope review",
            startDate: Date().addingTimeInterval(-761), endDate: Date().addingTimeInterval(1_800)
        ))
        let model = WorkspaceModel()
        for (suffix, width) in [("narrow", WorkspaceLayout.minimumSize.width), ("wide", WorkspaceLayout.standardSize.width)] {
            try renderBothAppearances(
                name: "compact-chrome-workspace-header-listening-\(suffix)",
                size: CGSize(width: width, height: House.Control.composer * 2),
                view: VStack(spacing: 0) {
                    OverlayShellHeader(status: .init(phase: .idle), fill: House.ColorToken.surfaceSunken, workspace: model)
                    OverlayShellHeader(status: .init(phase: .recording), fill: House.ColorToken.surfaceSunken, workspace: model)
                }
            )
        }
    }

    /// A real click on the header title opens Prepare: the title posts the
    /// tab switch the Live page and the workspace both follow.
    func testClickingTheHeaderTitleOpensPrepare() throws {
        let width = WorkspaceLayout.standardSize.width
        let hosting = NSHostingView(rootView: OverlayShellHeader(status: .init(phase: .idle), fill: House.ColorToken.surfaceSunken,
                                                                 workspace: WorkspaceModel())
                .frame(width: width, height: House.Control.composer))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: House.Control.composer)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
        }
        let opened = expectation(forNotification: .rtiSelectTab, object: nil) { note in
            (note.object as? String) == OverlayTab.setup.rawValue
        }
        // The middle of the title column, right of the traffic lights.
        let point = NSPoint(x: HouseChatMetrics.trafficLightInset + OverlayShellHeader.workspaceTitleWidth / 2,
                            y: House.Control.composer / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: hosting.convert(point, to: nil), modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        wait(for: [opened], timeout: 2)
    }

    /// The title's tooltip and VoiceOver line name the project when the
    /// title is a calendar event.
    func testHeaderTitleSummaryNamesTheProject() {
        XCTAssertEqual(OverlayHeaderTitle.summary(title: "Onboarding scope review", project: "Northwind app", state: "Ready"),
                       "Onboarding scope review, project Northwind app. State: Ready")
        XCTAssertEqual(OverlayHeaderTitle.summary(title: "Northwind app", project: nil, state: "Recording"),
                       "Northwind app. State: Recording")
    }

    /// The eye menu's project rows set only the project's own choice for the
    /// call type; the Settings default stays as it was, and "Use default"
    /// clears the choice.
    func testEyeMenuProjectRowsSetOnlyTheProjectChoice() throws {
        let suite = "rti.fixture.eye-menu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = ScreenshotPolicy(defaults: defaults)
        XCTAssertEqual(policy.global, .manual)
        OverlayScreenshotChoice.apply(.automatic, policy: policy, project: "Project A", callType: .research)
        XCTAssertEqual(policy.override(project: "Project A", callType: .research), .automatic)
        XCTAssertNil(policy.override(project: "Project A", callType: .client), "Another call type kept its default")
        XCTAssertEqual(policy.global, .manual, "The Settings default changed")
        OverlayScreenshotChoice.apply(.off, policy: policy, project: "Project A", callType: .research)
        XCTAssertEqual(policy.effective(project: "Project A", callType: .research), .off)
        XCTAssertEqual(policy.global, .manual)
        OverlayScreenshotChoice.apply(nil, policy: policy, project: "Project A", callType: .research)
        XCTAssertNil(policy.override(project: "Project A", callType: .research))
        XCTAssertEqual(policy.effective(project: "Project A", callType: .research), .manual)
        XCTAssertEqual(OverlayVisualContextButton.defaultLine(.manual), "Default: Manual only")
        XCTAssertEqual(OverlayVisualContextButton.defaultLine(.off), "Default: Off for every call (project choices wait)")
    }

    /// The eye menu's project section names whose calls it covers.
    func testScreenshotProjectSectionTitle() {
        XCTAssertEqual(OverlayVisualContextButton.projectSectionTitle(project: "Northwind app", callType: .research),
                       "Northwind app: Research calls")
        XCTAssertEqual(OverlayVisualContextButton.projectSectionTitle(project: "  ", callType: .client),
                       "This project's \(CallType.client.name) calls")
    }

    func testSavedChatFooterAtCompactAndStandardReaderWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-compact-chrome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(
            assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")
        ))
        let conversation = try await store.thread(
            id: "compact-chrome-fixture", title: "Northwind onboarding follow-up", surface: .rtiCopilot,
            session: nil, appVersion: "proof"
        )
        let committed = try await store.appendTurn(to: conversation, turn: .init(text: "What should we check before Thursday?"))
        _ = try await store.appendTurn(to: committed.conversation, turn: .init(
            text: "Confirm the owner of the onboarding note and the date of the next review.", role: .assistant
        ))
        let turns = root.appendingPathComponent("turns")
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        try #"{"ts":"2026-09-12T07:04:00Z","action":"Assist","userInput":"What comes next?","output":"Confirm the next review.","sources":[]}"#
            .write(to: turns.appendingPathComponent("2026-09-12.jsonl"), atomically: true, encoding: .utf8)
        let library = ChatLibraryModel(location: .init(store: store, legacyTurnsRoot: turns), now: { Date() })
        await library.loadIfNeeded()
        library.select(id: conversation.id)
        await library.loadDetail()
        XCTAssertNotNil(library.detail?.record)
        for (suffix, width) in headerWidths {
            try renderBothAppearances(
                name: "compact-chrome-chat-reader-\(suffix)",
                size: CGSize(width: width - House.Layout.chatRail, height: House.Layout.chatMinHeight),
                view: ChatLibraryReader(library: library).background(House.ColorToken.surfaceRaised)
            )
        }
        library.select(logID: "2026-09-12")
        try renderBothAppearances(
            name: "compact-chrome-dated-reader",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound - House.Layout.chatRail, height: House.Layout.chatMinHeight),
            view: ChatLibraryReader(library: library).background(House.ColorToken.surfaceRaised)
        )
    }

    private var headerWidths: [(String, CGFloat)] {
        [
            ("compact", OverlayAppearanceDefaults.widthRange.lowerBound),
            ("standard", OverlayAppearanceDefaults.defaultWidth)
        ]
    }
}
