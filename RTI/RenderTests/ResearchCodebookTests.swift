import Foundation
import RTICore
import XCTest

final class ResearchCodebookTests: XCTestCase {
    private func quote(_ id: String, session: String = "session1", original: String = "我把晨杯放在侧袋。", moderator: Bool = false) -> ResearchQuote {
        ResearchQuote(sessionID: session, turnID: id, group: session == "session1" ? "G1" : "G2", offsetMs: moderator ? 1000 : 2000, original: original,
                      speaker: .init(rawSpeaker: moderator ? "self" : "remote_1", label: moderator ? "Me" : "Them", leg: moderator ? "Me" : "Them", confidence: "legOnly", seat: nil, segment: nil, moderator: moderator),
                      questionID: "S1Q2", markerID: "m1", markerLabel: "Bag test", showEventID: "shown1", shownItemIDs: ["v1/board/A1"], shownCodes: ["A1"], packageRevision: "v1", revealRecorded: false)
    }

    private func item(_ name: String, _ turn: String, aliases: [String] = []) -> ResearchProposal.Item {
        .init(name: name, aliases: aliases, type: .brand, turnID: turn, point: "Described the cup in use.", valence: .positive)
    }

    func testOriginalFromOneTurnOnlyAndUnconfirmedNameHint() throws {
        var book = ResearchCodebook()
        let prompt = quote("m", original: "小禾，你把杯子放在哪里？", moderator: true), response = quote("r")
        let first = ResearchProposal(entries: [item("Morning Cup（晨杯）", "r"), item("Spurious", "nonexistent"), item("Facilitator opinion", "m")], names: [.init(moderatorTurnID: "m", respondentTurnID: "r", name: "小禾")])
        book.apply(first, sources: [prompt, response]); book.apply(first, sources: [prompt, response])
        XCTAssertEqual(book.cards.count, 1)
        let card = try XCTUnwrap(book.cards.first); XCTAssertEqual(card.entries.count, 1)
        let e = try XCTUnwrap(card.entries.first)
        XCTAssertEqual(e.evidence, response); XCTAssertEqual(e.evidence.original, "我把晨杯放在侧袋。")
        XCTAssertEqual(e.inferredName, "小禾"); XCTAssertEqual(e.evidence.speaker.confidence, "legOnly")
        XCTAssertEqual(e.evidence.shownItemIDs, ["v1/board/A1"])
    }

    func testCapBilingualMergeRenamesPinsAndDropsWinOnReplay() throws {
        let first = quote("one"), second = quote("two", session: "session2", original: "It fits my side pocket.")
        var book = ResearchCodebook(); book.seed("Morning Cup（晨杯）", type: .brand)
        book.apply(.init(entries: [item("晨杯", "one")], names: nil), sources: [first])
        let id = try XCTUnwrap(book.cards.first?.id)
        book.edit(.rename(id, "Pocket cup")); book.edit(.pin(id, true))
        book.apply(.init(entries: [item("Morning Cup", "two", aliases: ["晨杯"])], names: nil), sources: [second])
        XCTAssertEqual(book.cards.count, 1); XCTAssertEqual(book.cards[0].name, "Pocket cup"); XCTAssertTrue(book.cards[0].pinned)
        XCTAssertEqual(book.cards[0].entries.map(\.evidence.original), [first.original, second.original]); XCTAssertEqual(book.scoped(to: "session2").cards[0].entries.count, 1)
        let many = (0 ..< 10).map { item("Concept \($0)", "one") }
        book.apply(.init(entries: many, names: nil), sources: [first]); XCTAssertEqual(book.cards.count, 9)
        book.edit(.merge(book.cards[1].id, into: id)); XCTAssertEqual(book.cards[0].entries.count, 2)
        book.edit(.drop(id)); book.apply(.init(entries: [item("晨杯", "one")], names: nil), sources: [first]); XCTAssertFalse(book.cards.contains { $0.id == id || $0.name == "晨杯" })
    }

    func testConcurrentSessionsPreserveBothGroupsAndOnlyLocalEntriesGoInSessionFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("fixture"), one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        for dir in [project, one, two] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ResearchCodebookStore.Location(session: .init(id: "session1", group: "G1", startedAt: Date(timeIntervalSince1970: 0), folder: "one"), directory: one, project: project)
        let later = ResearchCodebookStore.Location(session: .init(id: "session2", group: "G2", startedAt: Date(timeIntervalSince1970: 100), folder: "two"), directory: two, project: project)
        let a = ResearchCodebookStore(), b = ResearchCodebookStore()
        let old = try await a.existingBook(in: one); XCTAssertTrue(old.cards.isEmpty)
        _ = try await a.update(first, .prepare(seeds: ["brand | Morning Cup（晨杯）"], hypotheses: []))
        let q1 = quote("r1"), q2 = quote("r2", session: "session2", original: "I hang it from the handle.")
        async let g1 = a.update(first, .pass(.init(entries: [item("晨杯", "r1")], names: nil), [q1], endMs: 2500))
        async let g2 = b.update(later, .pass(.init(entries: [item("Morning Cup", "r2")], names: nil), [q2], endMs: 2800))
        _ = try await (g1, g2)
        let merged = try await a.existingBook(in: project); let local = try await a.existingBook(in: two)
        XCTAssertEqual(merged.sessions.count, 2); XCTAssertEqual(merged.cards.count, 1); XCTAssertEqual(Set(merged.cards[0].entries.map(\.evidence.original)), [q1.original, q2.original]); XCTAssertEqual(local.cards[0].entries.map(\.evidence.original), [q2.original])
        try await a.star(q2, in: two); try await a.star(q2, in: two)
        let stars = try String(contentsOf: two.appendingPathComponent("quotes.jsonl"), encoding: .utf8).split(separator: "\n"); XCTAssertEqual(stars.count, 1)
        let star = try JSONDecoder().decode(ResearchQuote.self, from: Data(stars[0].utf8)); XCTAssertEqual(star, q2)
        XCTAssertEqual(ResearchCodebookStore.sidecarFields(in: two).count, 5)
        XCTAssertTrue(try String(contentsOf: project.appendingPathComponent("codebook.md"), encoding: .utf8).contains(q1.original))
    }

    func testChangedOrCorruptProjectDataIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), other = root.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: other)
        let loc = ResearchCodebookStore.Location(session: .init(id: "id", group: nil, startedAt: Date(), folder: "fixture"), directory: root, project: nil)
        let store = ResearchCodebookStore(); let book = root.appendingPathComponent("codebook.json")
        try FileManager.default.createSymbolicLink(at: book, withDestinationURL: other)
        do { _ = try await store.update(loc, .prepare(seeds: ["One"], hypotheses: [])); XCTFail("Accepted symlink") } catch {}
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "original")
    }
}
