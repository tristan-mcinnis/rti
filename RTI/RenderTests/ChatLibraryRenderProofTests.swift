import AppKit
import HouseChatCore
import SwiftUI
import XCTest

/// The Chats library in the Sessions window: the rail, the reader, the saved
/// source list, a dated legacy log, and the whole window in Chats mode.
///
/// Every fixture lives in a temporary root, so no proof reads the live vault,
/// the real Application Support folder, or a stored chat. PNG prefix
/// `chat-library-`. The design check is a person reading every PNG.
final class ChatLibraryRenderProofTests: RenderProofTestCase {
    private var root: URL!
    private var store: ChatThreadStore!
    private var location: ChatLibraryLocation!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-chat-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try ChatThreadStore(roots: ChatThreadStore.Roots(
            assets: root.appendingPathComponent("chat-assets", isDirectory: true),
            threads: root.appendingPathComponent("chats/threads", isDirectory: true)
        ))
        location = ChatLibraryLocation(
            store: store,
            legacyTurnsRoot: root.appendingPathComponent("turns", isDirectory: true)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        // A remembered list choice must not leak into other proof classes.
        UserDefaults.standard.removeObject(forKey: SessionsWindowModel.railVisibleKey)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var windowSize: CGSize {
        CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
    }

    private var minimumSize: CGSize {
        CGSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)
    }

    /// Three saved chats, one dated legacy log, and one damaged file, all in
    /// the temporary root.
    private func seed() async throws {
        let report = Data("%PDF-1.4 an invented report".utf8)
        let pinned = try await store.thread(
            id: "chat-pinned", title: "Northwind pricing teardown", surface: .rtiCopilot, session: nil, appVersion: "proof"
        )
        let committed = try await store.appendTurn(to: pinned, turn: ChatThreadStore.SubmittedTurn(
            text: "What does the pricing page do wrong?",
            attachments: [ChatThreadStore.SubmittedAttachment(
                kind: .pdf,
                name: "northwind-pricing.pdf",
                path: root.appendingPathComponent("northwind-pricing.pdf").path,
                byteCount: report.count,
                pageCount: 12,
                originalBytes: report,
                originalExtension: "pdf",
                extractedText: "The plan table is doing too much."
            )]
        ))
        _ = try await store.appendTurn(
            to: committed.conversation,
            turn: ChatThreadStore.SubmittedTurn(
                text: "Three tiers, one highlighted, and the FAQ moves under the table.",
                role: .assistant
            )
        )
        _ = try await store.setPinned(id: "chat-pinned", true)

        let plain = try await store.thread(
            id: "chat-plain", title: nil, surface: .rtiCopilot, session: nil, appVersion: "proof"
        )
        _ = try await store.appendTurn(to: plain, turn: ChatThreadStore.SubmittedTurn(
            text: "Summarise the onboarding scope for Northwind before Thursday."
        ))

        let quiet = try await store.thread(
            id: "chat-quiet", title: "Fabrikam loyalty card research", surface: .rtiMeeting, session: nil, appVersion: "proof"
        )
        _ = try await store.appendTurn(to: quiet, turn: ChatThreadStore.SubmittedTurn(text: "Recap the last ten minutes."))

        // A file a newer build, or a bad write, left behind.
        let threads = root.appendingPathComponent("chats/threads", isDirectory: true)
        try Data("{ not json".utf8).write(to: threads.appendingPathComponent("broken.json"))

        // One dated legacy log in the shape VaultLogStore writes, with one row
        // that belongs to a saved chat: that row is counted, never shown twice.
        let turns = root.appendingPathComponent("turns", isDirectory: true)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let day = [
            #"{"ts":"2026-09-12T07:04:00Z","action":"Assist","mode":"Meeting","inSession":true,"userInput":"What is their objection to the price?","output":"They compared it to the incumbent's entry tier and could not see what the extra spend bought.","sources":["northwind-brief.md"]}"#,
            #"{"ts":"2026-09-12T07:31:00Z","action":"Recap","mode":null,"inSession":true,"userInput":"Recap so far","output":"Pricing framing, tier naming, and the FAQ placement.","sources":[]}"#,
            #"{"ts":"2026-09-12T08:00:00Z","action":"Ask","userInput":"This one is already a saved chat","output":"listed under Chats","threadID":"chat-pinned"}"#,
            "",
        ].joined(separator: "\n")
        try day.write(to: turns.appendingPathComponent("2026-09-12.jsonl"), atomically: true, encoding: .utf8)

        // A day whose every readable row is a saved chat: it is listed as a
        // chat, not as a dated log as well.
        let projected = [
            #"{"ts":"2026-09-11T07:04:00Z","action":"Ask","userInput":"a saved chat's own turn","output":"already listed","threadID":"chat-quiet"}"#,
            "",
        ].joined(separator: "\n")
        try projected.write(to: turns.appendingPathComponent("2026-09-11.jsonl"), atomically: true, encoding: .utf8)
    }

    private func makeLibrary() async throws -> ChatLibraryModel {
        try await seed()
        let library = ChatLibraryModel(location: location, now: { Date() })
        await library.loadIfNeeded()
        return library
    }

    // MARK: - Proofs

    func testTheChatsRailAndReaderRenderInBothAppearances() async throws {
        let library = try await makeLibrary()
        XCTAssertEqual(library.rows.count, 4, "three chats and the damaged file")
        XCTAssertEqual(library.legacyLogs.count, 1, "the projection-only day is not a log")
        XCTAssertEqual(library.linkedLogDayCount, 1)

        library.select(id: "chat-pinned")
        await library.loadDetail()
        let detail = try XCTUnwrap(library.detail)
        XCTAssertEqual(detail.turns.count, 2)
        XCTAssertEqual(detail.sources.count, 1)
        XCTAssertEqual(detail.sources.first?.state, .verified)

        let pane = HStack(spacing: 0) {
            ChatLibraryRail(library: library)
                .frame(width: House.Layout.chatRail)
            Rectangle()
                .fill(House.ColorToken.divider)
                .frame(width: House.hairline)
            ChatLibraryReader(library: library)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)

        try renderBothAppearances(name: "chat-library-window", size: windowSize, view: pane)
        try renderBothAppearances(name: "chat-library-minimum", size: minimumSize, view: pane)
    }

    func testADatedLogRendersAsDatedEntries() async throws {
        let library = try await makeLibrary()
        library.select(logID: "2026-09-12")

        let pane = HStack(spacing: 0) {
            ChatLibraryRail(library: library)
                .frame(width: House.Layout.chatRail)
            Rectangle()
                .fill(House.ColorToken.divider)
                .frame(width: House.hairline)
            ChatLibraryReader(library: library)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)

        try renderBothAppearances(name: "chat-library-dated-log", size: windowSize, view: pane)
    }

    func testADamagedChatAndTheEmptyStateRenderInBothAppearances() async throws {
        let library = try await makeLibrary()
        library.select(id: "broken")
        await library.loadDetail()
        XCTAssertNotNil(library.detailNoticeText, "a damaged chat says so rather than showing invented turns")

        let pane = HStack(spacing: 0) {
            ChatLibraryRail(library: library)
                .frame(width: House.Layout.chatRail)
            Rectangle()
                .fill(House.ColorToken.divider)
                .frame(width: House.hairline)
            ChatLibraryReader(library: library)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(House.ColorToken.surface)

        try renderBothAppearances(name: "chat-library-damaged", size: windowSize, view: pane)
    }

    /// The whole window in Chats mode: the mode switch, the chats rail, and
    /// the reader, with the meeting list left alone behind it.
    func testTheSessionsWindowInChatsModeRendersInBothAppearances() async throws {
        let library = try await makeLibrary()
        library.select(id: "chat-pinned")
        await library.loadDetail()

        let model = SessionsWindowModel(dependencies: .init(
            contentSearch: nil,
            generateTitle: nil,
            persistGeneratedTitle: { _, _ in XCTFail("a proof must never write a title") },
            now: { Date() },
            chatLibrary: location
        ))
        model.mode = .chats
        model.isRailVisible = true
        await model.loadActiveLibrary()

        try renderBothAppearances(name: "chat-library-sessions-window", size: windowSize, view: SessionsBrowserView(model: model))
    }
}
