import AppKit
import HouseDesign
import HouseChatCore
import RTICore
import SwiftUI
import XCTest

final class WorkspaceRenderProofTests: RenderProofTestCase {
    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
    }

    override func tearDown() async throws {
        WorkspaceModel.shared.select(.live)
        SessionCoordinator.shared.seedForRenderProof(entries: [], interim: nil, phase: .idle, startedAt: nil)
        LLMController.shared.seedForRenderProof(entries: [])
        try await super.tearDown()
    }

    func testEveryPageInBothAppearances() async throws {
        let model = WorkspaceModel()
        await model.sessions.reload()
        model.sessions.setRailVisible(true, remember: false)
        model.settings.pane = .about
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        SessionCoordinator.shared.seedForRenderProof(
            entries: RenderFixtures.speakerTurns, interim: nil, phase: .recording,
            startedAt: Date().addingTimeInterval(-761)
        )
        for page in WorkspaceModel.Page.allCases {
            model.select(page)
            try renderBothAppearances(
                name: "workspace-\(page.rawValue.lowercased())",
                size: CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight),
                view: WorkspaceView(model: model, modes: .inMemory())
            )
        }
        model.select(.live)
        try renderBothAppearances(
            name: "workspace-live-minimum",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: OverlayAppearanceDefaults.defaultHeight),
            view: WorkspaceView(model: model, modes: .inMemory())
        )
    }

    func testPopulatedChatReaderKeepsReturnNavigationWithListHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ChatThreadStore(roots: .init(
            assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")
        ))
        let conversation = try await store.thread(
            id: "workspace-fixture", title: "Onboarding follow-up", surface: .rtiCopilot,
            session: nil, appVersion: "proof"
        )
        let committed = try await store.appendTurn(to: conversation, turn: .init(text: "Who owns the decision note?"))
        _ = try await store.appendTurn(to: committed.conversation, turn: .init(
            text: "Speaker 2 agreed to write the note before Thursday.", role: .assistant
        ))
        let model = WorkspaceModel(sessions: SessionsWindowModel(dependencies: .init(
            contentSearch: nil, now: { Date() },
            chatLibrary: ChatLibraryLocation(store: store, legacyTurnsRoot: root.appendingPathComponent("turns"))
        )))
        model.select(.chats)
        model.sessions.setRailVisible(false, remember: false)
        await model.sessions.chatLibrary.reload()
        model.sessions.chatLibrary.select(id: conversation.id)
        await model.sessions.chatLibrary.loadDetail()
        try renderBothAppearances(
            name: "workspace-chat-reader-list-hidden",
            size: CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight),
            view: WorkspaceView(model: model, modes: .inMemory())
        )
        model.select(.sessions)
        XCTAssertEqual(model.sessions.mode, .sessions)
        model.select(.chats)
        XCTAssertEqual(model.sessions.chatLibrary.openID, conversation.id)
    }

    /// Reproduces the lost return route in the saved chat reader, including
    /// an unavailable library, while keeping the selected session and query.
    func testChatsAlwaysReturnToTheSelectedSession() async throws {
        let model = WorkspaceModel()
        await model.sessions.reload()
        model.showSession()
        let selection = try XCTUnwrap(model.sessions.openRow?.id)
        model.sessions.railQuery = "scope"
        model.select(.chats)
        XCTAssertEqual(model.sessions.mode, .chats)
        model.select(.sessions)
        XCTAssertEqual(model.sessions.mode, .sessions)
        XCTAssertEqual(model.sessions.openRow?.id, selection)
        XCTAssertEqual(model.sessions.railQuery, "scope")
        XCTAssertTrue(model.sessions.isWindowVisible)
    }

    func testSettingsReturnAndNavigationDoNotChangeCaptureOrChat() {
        let model = WorkspaceModel()
        LLMController.shared.seedForRenderProof(entries: RenderFixtures.assistTurns)
        let turns = LLMController.shared.entries.count
        SessionCoordinator.shared.seedForRenderProof(entries: RenderFixtures.speakerTurns, interim: nil, phase: .paused, startedAt: nil)
        model.select(.chats)
        model.showSettings(.general)
        model.showSettings(.logs)
        model.leaveSettings()
        XCTAssertEqual(model.page, .chats)
        for page in WorkspaceModel.Page.allCases { model.select(page) }
        XCTAssertEqual(SessionCoordinator.shared.phase, .paused)
        XCTAssertEqual(LLMController.shared.entries.count, turns)
        model.select(.live)
        XCTAssertFalse(model.sessions.isWindowVisible)
    }

    func testLegacyEntryPointsUseTheSameWorkspace() {
        let model = WorkspaceModel.shared
        WindowCoordinator.shared.showSessions()
        XCTAssertEqual(model.page, .sessions)
        model.select(.chats)
        WindowCoordinator.shared.showSessions()
        XCTAssertEqual(model.page, .sessions)
        WindowCoordinator.shared.showSessionsControl(tab: .general)
        XCTAssertEqual(model.page, .settings)
        XCTAssertEqual(model.settings.pane, .general)
        SettingsWindowController.shared.show(pane: .logs)
        XCTAssertEqual(model.settings.pane, .logs)
        WindowCoordinator.shared.showOverlay()
        XCTAssertEqual(model.page, .live)
        WindowCoordinator.shared.showAbout()
        XCTAssertEqual(model.page, .settings)
        XCTAssertEqual(model.settings.pane, .about)
    }
}
