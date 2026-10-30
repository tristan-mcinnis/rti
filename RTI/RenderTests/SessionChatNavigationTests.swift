import HouseChatCore
import RTICore
import SwiftUI
import XCTest

@MainActor
final class SessionChatNavigationTests: RenderProofTestCase {
    private var root: URL!
    private var priorConfig: String?
    private var location: ChatLibraryLocation!

    override func setUp() async throws {
        try await super.setUp()
        SetupTabView.readsCalendar = false
        priorConfig = ProcessInfo.processInfo.environment["RTI_CONFIG_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-navigation-\(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        for (folder, id) in [("2026-10-30 090000", "session-alpha"), ("2026-10-29 090000", "session-beta")] {
            let directory = sessions.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (file, text) in [("notes.md", "# Notes\n\nKeep the selected reading origin."), ("transcript.md", "Speaker 1: Discuss the scope."), ("chat.md", "# Session chat\n\nArchived answer.")] {
                try text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            let metadata = SessionArchiveMetadata(
                sessionId: id, systemAudioStartOffsetMs: nil, micAudioFile: nil,
                systemAudioFile: nil, mode: nil, workstream: nil, durationSeconds: 60
            )
            try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("session.json"))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "sessions_dir": sessions.path,
            "recordings_dir": root.appendingPathComponent("kb/databases/meetings/recordings").path
        ])
        try data.write(to: config.appendingPathComponent("config.json"))
        setenv("RTI_CONFIG_HOME", config.path, 1)
        let store = try ChatThreadStore(roots: .init(
            assets: root.appendingPathComponent("assets"), threads: root.appendingPathComponent("threads")
        ))
        location = ChatLibraryLocation(store: store, legacyTurnsRoot: root.appendingPathComponent("turns"))
        for (id, link) in [
            ("linked", Optional(SessionLink(kind: "rti-session", id: "session-alpha", label: "Session"))),
            ("standalone", nil),
            ("unavailable", Optional(SessionLink(kind: "rti-session", id: "absent-session", label: "Session"))),
            ("wrong-kind", Optional(SessionLink(kind: "other", id: "session-alpha", label: "Session")))
        ] {
            let record = try await store.thread(id: id, title: id, surface: .rtiCopilot, session: link, appVersion: "test")
            _ = try await store.appendTurn(to: record, turn: .init(text: "Discuss the scope."))
        }
    }

    override func tearDown() async throws {
        if let priorConfig { setenv("RTI_CONFIG_HOME", priorConfig, 1) }
        else { unsetenv("RTI_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func workspace(loadChats: Bool = true) async -> WorkspaceModel {
        let sessions = SessionsWindowModel(dependencies: .init(contentSearch: nil, now: { Date() }, chatLibrary: location))
        let model = WorkspaceModel(sessions: sessions)
        await sessions.reload()
        if loadChats { await sessions.chatLibrary.reload() }
        model.select(.sessions)
        return model
    }

    func testSessionChatRoundTripKeepsExactFileQueryAndRailChoice() async throws {
        let model = await workspace()
        let session = try XCTUnwrap(model.sessions.rows.first { $0.sessionID == "session-alpha" })
        model.sessions.open(session.id)
        model.sessions.selectFile(named: "notes")
        model.sessions.railQuery = "scope"
        model.sessions.setRailVisible(false, remember: false)
        let origin = model.sessions.readingOrigin
        XCTAssertEqual(model.sessions.relatedChats.map(\.id), ["linked"])
        model.openRelatedChat(id: "linked")
        XCTAssertEqual(model.page, .chats)
        XCTAssertEqual(model.sessions.chatLibrary.openID, "linked")
        XCTAssertEqual(model.returnSessionRow?.id, session.id)
        model.returnToSession(try XCTUnwrap(model.returnSessionRow))
        XCTAssertEqual(model.page, .sessions)
        XCTAssertEqual(model.sessions.readingOrigin, origin)
        XCTAssertEqual(model.sessions.railQuery, "scope")
        XCTAssertEqual(model.sessions.chatLibrary.openID, "linked")
    }

    func testGlobalChatReturnKeepsTheAlreadyOpenSessionFile() async throws {
        let model = await workspace()
        let session = try XCTUnwrap(model.sessions.rows.first { $0.sessionID == "session-alpha" })
        model.sessions.open(session.id)
        model.sessions.selectFile(named: "transcript")
        model.sessions.chatLibrary.select(id: "linked")
        model.select(.chats)
        model.returnToSession(try XCTUnwrap(model.returnSessionRow))
        XCTAssertEqual(model.sessions.selectedFile?.name, "transcript")
        model.prepareToResumeChat(id: "linked")
        model.select(.live)
        XCTAssertEqual(model.chatOrigin?.fileName, "transcript")
    }

    func testLinksUseSessionMetadataAndNeverTitlesFoldersOrOtherKinds() async throws {
        let model = await workspace()
        for id in ["standalone", "wrong-kind", "unavailable"] {
            model.sessions.chatLibrary.select(id: id)
            model.select(.chats)
            XCTAssertTrue(model.linkedSessionRows.isEmpty)
            XCTAssertNil(model.returnSessionRow)
        }
        XCTAssertTrue(model.selectedChatHasSessionLink, "A missing archive stays visibly linked but has no fabricated route")
        model.prepareToResumeChat(id: "standalone")
        model.select(.live)
        XCTAssertNil(model.chatOrigin)
        XCTAssertNil(model.returnSessionRow)
    }

    func testRelatedChatsLoadBeforeVisitingGlobalChats() async throws {
        let model = await workspace(loadChats: false)
        model.sessions.open(try XCTUnwrap(model.sessions.rows.first { $0.sessionID == "session-alpha" }).id)
        model.sessions.selectFile(named: "chat")
        XCTAssertTrue(model.sessions.relatedChats.isEmpty)
        await model.sessions.chatLibrary.reload() // The session Chat reader's structured task.
        XCTAssertEqual(model.sessions.relatedChats.map(\.id), ["linked"])
        model.openRelatedChat(id: "linked")
        XCTAssertEqual(model.page, .chats)
    }

    func testResumeKeepsOriginThroughOldThreadAndInternalResetThenClearsOnNewChat() async throws {
        let model = await workspace()
        let session = try XCTUnwrap(model.sessions.rows.first { $0.sessionID == "session-alpha" })
        model.sessions.open(session.id)
        model.sessions.selectFile(named: "transcript")
        model.openRelatedChat(id: "linked")
        model.prepareToResumeChat(id: "linked")
        model.select(.live)
        model.conversationDidChange(to: "previous-chat")
        XCTAssertNil(model.returnSessionRow, "The old composer must not show the pending chat's session")
        XCTAssertEqual(model.chatOrigin?.rowID, session.id)
        model.conversationWillReset(resumingChatID: "linked")
        XCTAssertEqual(model.chatOrigin?.rowID, session.id)
        model.conversationDidFinishResume(id: "older-request", succeeded: false)
        XCTAssertEqual(model.chatOrigin?.rowID, session.id, "An older completion cannot retire the current origin")
        model.conversationDidFinishResume(id: "linked", succeeded: true)
        model.conversationDidChange(to: "linked")
        XCTAssertEqual(model.returnSessionRow?.id, session.id)
        model.conversationWillReset(resumingChatID: nil)
        XCTAssertNil(model.returnSessionRow)
        XCTAssertNil(model.chatOrigin)
    }

    func testFailedStoredChatHandoffClearsPendingSessionOrigin() async throws {
        let model = await workspace()
        let controller = LLMController(chatStore: location.store, storeIsInjected: true, modeStore: .inMemory(), turnLogger: { _ in })
        await controller.resumeChat(id: "standalone")
        XCTAssertEqual(controller.currentConversationID, "standalone")
        let observer = NotificationCenter.default.addObserver(forName: .rtiComposerDidFinishResume, object: nil, queue: .main) { note in
            guard (note.object as? LLMController) === controller,
                  let id = note.userInfo?["conversationID"] as? String,
                  let succeeded = note.userInfo?["succeeded"] as? Bool else { return }
            MainActor.assumeIsolated {
                model.conversationDidFinishResume(id: id, succeeded: succeeded)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.prepareToResumeChat(id: "linked")
        model.select(.live)
        XCTAssertNotNil(model.chatOrigin)
        XCTAssertNil(model.returnSessionRow)
        let archive = try ConversationArchive(root: root.appendingPathComponent("threads"))
        try Data("{ broken stored chat".utf8).write(to: archive.fileURL(for: "linked"))
        await controller.resumeChat(id: "linked")
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(controller.currentConversationID, "standalone")
        XCTAssertNil(model.chatOrigin, "The failed handoff cannot label the old composer with the requested session")
        XCTAssertNil(model.returnSessionRow)
    }

    func testReturningToChatsRefreshesAnArchiveCreatedAfterTheFirstVisit() async throws {
        let model = await workspace()
        XCTAssertFalse(model.sessions.rows.contains { $0.sessionID == "new-session" })
        let directory = root.appendingPathComponent("sessions/2026-10-30 110000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "# Transcript\n\nNew archived session.".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let metadata = SessionArchiveMetadata(
            sessionId: "new-session", systemAudioStartOffsetMs: nil, micAudioFile: nil,
            systemAudioFile: nil, mode: nil, workstream: nil, durationSeconds: 60
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("session.json"))
        let chat = try await location.store.thread(
            id: "new-session-chat", title: "New saved chat", surface: .rtiCopilot,
            session: SessionLink(kind: "rti-session", id: "new-session", label: "Session"), appVersion: "test"
        )
        _ = try await location.store.appendTurn(to: chat, turn: .init(text: "Question in the new saved chat"))
        model.select(.chats)
        await model.reloadVisiblePage()
        model.sessions.chatLibrary.select(id: "new-session-chat")
        XCTAssertEqual(model.returnSessionRow?.sessionID, "new-session")
    }

    func testLinkedReturnChromeInBothAppearances() async throws {
        let model = await workspace()
        model.sessions.open(try XCTUnwrap(model.sessions.rows.first { $0.sessionID == "session-alpha" }).id)
        model.sessions.selectFile(named: "chat")
        model.sessions.setRailVisible(false, remember: false)
        model.openRelatedChat(id: "linked")
        await model.sessions.chatLibrary.loadDetail()
        try renderBothAppearances(
            name: "session-chat-linked-return", size: WorkspaceLayout.minimumSize,
            view: WorkspaceView(model: model, modes: .inMemory())
        )
        model.prepareToResumeChat(id: "linked")
        model.conversationDidFinishResume(id: "linked", succeeded: true)
        model.select(.live)
        try renderBothAppearances(
            name: "session-chat-live-return", size: WorkspaceLayout.minimumSize,
            view: WorkspaceView(model: model, modes: .inMemory())
        )
    }
}
