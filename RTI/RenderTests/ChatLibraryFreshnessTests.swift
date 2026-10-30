import Foundation
import HouseChatCore
import RTICore
import XCTest

@MainActor
final class ChatLibraryFreshnessTests: XCTestCase {
    private var root: URL!
    private var store: ChatThreadStore!
    private var model: WorkspaceModel!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-chat-freshness-\(UUID().uuidString)")
        store = try ChatThreadStore(roots: .init(
            assets: root.appendingPathComponent("assets"),
            threads: root.appendingPathComponent("threads"),
            removeProjections: { _ in VaultLogStore.ProjectionCleanup() }
        ))
        model = WorkspaceModel(sessions: SessionsWindowModel(dependencies: .init(
            contentSearch: nil,
            now: { Date() },
            chatLibrary: ChatLibraryLocation(store: store, legacyTurnsRoot: root.appendingPathComponent("turns"))
        )))
    }

    override func tearDown() async throws {
        model = nil
        store = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        try await super.tearDown()
    }

    private func saveChat(_ id: String, title: String) async throws -> ConversationRecord {
        let record = try await store.thread(id: id, title: title, surface: .rtiCopilot, session: nil, appVersion: "test")
        return try await store.appendTurn(to: record, turn: .init(text: "Question for \(title)")).conversation
    }

    func testReturningToChatsShowsThreadsSavedWhileOnLive() async throws {
        _ = try await saveChat("first", title: "First conversation")
        model.select(.chats)
        await model.sessions.loadActiveLibrary()
        XCTAssertEqual(model.sessions.chatLibrary.rows.count, 1)

        model.select(.live)
        _ = try await saveChat("second", title: "Second conversation")
        model.select(.chats)
        await model.sessions.loadActiveLibrary()

        XCTAssertEqual(Set(model.sessions.chatLibrary.rows.map(\.id)), ["first", "second"])
    }

    func testReturningToTheSameChatRefreshesTurnsAndKeepsSearchAndSelection() async throws {
        var record = try await saveChat("continued", title: "Scope discussion")
        model.select(.chats)
        await model.sessions.loadActiveLibrary()
        let library = model.sessions.chatLibrary
        library.select(id: record.id)
        await library.loadDetail()
        library.query = "Scope"
        XCTAssertEqual(library.detail?.turns.count, 1)

        model.select(.live)
        record = try await store.appendTurn(to: record, turn: .init(text: "The revised scope is ready.", role: .assistant)).conversation
        model.select(.chats)
        await model.sessions.loadActiveLibrary()

        XCTAssertEqual(library.openID, record.id)
        XCTAssertEqual(library.query, "Scope")
        XCTAssertEqual(library.detail?.turns.count, 2)
        XCTAssertTrue(library.detail?.turns.contains { $0.text == "The revised scope is ready." } == true)
    }

    func testSelectingTheAlreadyOpenChatKeepsItsLoadedDetail() async throws {
        let record = try await saveChat("selected", title: "Selected conversation")
        let library = model.sessions.chatLibrary
        await library.reload()
        library.select(id: record.id)
        await library.loadDetail()
        XCTAssertEqual(library.detail?.turns.count, 1)

        library.select(id: record.id)

        XCTAssertEqual(library.detail?.turns.count, 1, "The unchanged selection does not restart the view's detail task")
    }

    func testManualRefreshAlsoUpdatesTheSelectedDetail() async throws {
        var record = try await saveChat("manual", title: "Manual refresh")
        let library = model.sessions.chatLibrary
        await library.reload()
        library.select(id: record.id)
        await library.loadDetail()
        record = try await store.appendTurn(to: record, turn: .init(text: "An additional turn", role: .assistant)).conversation

        await library.reload()

        XCTAssertEqual(library.openID, record.id)
        XCTAssertEqual(library.detail?.turns.count, 2)
    }
}
