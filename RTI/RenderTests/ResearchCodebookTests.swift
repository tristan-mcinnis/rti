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
        let firstChange = ResearchCodebookStore.Change.pass(.init(entries: [item("晨杯", "r1")], names: nil), [q1], endMs: 2500)
        let secondChange = ResearchCodebookStore.Change.pass(.init(entries: [item("Morning Cup", "r2")], names: nil), [q2], endMs: 2800)
        async let g1 = a.update(first, firstChange)
        async let g2 = b.update(later, secondChange)
        _ = try await (g1, g2)
        let merged = try await a.existingBook(in: project); let local = try await a.existingBook(in: two)
        XCTAssertEqual(merged.sessions.count, 2); XCTAssertEqual(merged.cards.count, 1); XCTAssertEqual(Set(merged.cards[0].entries.map(\.evidence.original)), [q1.original, q2.original]); XCTAssertEqual(local.cards[0].entries.map(\.evidence.original), [q2.original])
        try await a.star(q2, in: two); try await a.star(q2, in: two)
        let stars = try String(contentsOf: two.appendingPathComponent("quotes.jsonl"), encoding: .utf8).split(separator: "\n"); XCTAssertEqual(stars.count, 1)
        let star = try JSONDecoder().decode(ResearchQuote.self, from: Data(stars[0].utf8)); XCTAssertEqual(star, q2)
        XCTAssertEqual(ResearchCodebookStore.sidecarFields(in: two).count, 5)
        XCTAssertTrue(try String(contentsOf: project.appendingPathComponent("codebook.md"), encoding: .utf8).contains(q1.original))
    }

    func testExposureCorrectionAndUpgradePreserveCitedWordsOnBothSidesOfABoundary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loc = ResearchCodebookStore.Location(session: .init(id: "session1", group: "G1", startedAt: Date(), folder: folder.lastPathComponent), directory: folder, project: nil)
        let store = ResearchCodebookStore(), q = quote("r1")
        let first = SessionNote(id: "a", kind: .stimulus, offsetMs: 1500, shownCodes: ["A1"], packageRevision: "r")
        let second = SessionNote(id: "b", kind: .stimulus, offsetMs: 3000, shownCodes: ["B1"], revealed: true, packageRevision: "r")
        try SessionMarkerJournal.append(first, in: folder); try SessionMarkerJournal.append(second, in: folder)
        _ = try await store.update(loc, .pass(.init(entries: [item("晨杯", "r1")], names: nil), [q], endMs: 2200))
        try await store.star(q, in: folder)
        try await store.reanchor(in: folder, upgradedTurns: [.init(speaker: "Them", startMs: 3300, text: q.original)])
        let anchored = try await store.existingBook(in: folder)
        let before = try XCTUnwrap(anchored.cards.first?.entries.first?.evidence)
        XCTAssertEqual(before.offsetMs, 2000); XCTAssertEqual(before.upgradedOffsetMs, 3300); XCTAssertEqual(before.anchorNeedsReview, true)
        XCTAssertEqual(before.shownCodes, ["A1"]); XCTAssertEqual(before.original, q.original)
        let corrected = SessionNote(id: "replay", kind: .correction, offsetMs: 5000, revealed: true, packageRevision: "r", replaces: "b", replacement: .init(text: "B1", shownCodes: ["B1"], offsetMs: 1800))
        try SessionMarkerJournal.append(corrected, in: folder)
        let refreshed = try await store.update(loc, .refresh)
        let after = try XCTUnwrap(refreshed.cards.first?.entries.first?.evidence)
        XCTAssertEqual(after.shownCodes, ["B1"]); XCTAssertEqual(after.anchorNeedsReview, false); XCTAssertEqual(after.showEventID, "b"); XCTAssertEqual(after.original, q.original)
        let line = try String(contentsOf: folder.appendingPathComponent("quotes.jsonl"), encoding: .utf8)
        let star = try JSONDecoder().decode(ResearchQuote.self, from: Data(line.utf8))
        XCTAssertEqual(star, after)
    }

    func testUnavailableProjectKeepsSessionAndRetryMergesIntoExistingAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("group"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let place = ResearchCodebookStore.Location(session: .init(id: "session1", group: "G1", startedAt: Date(), folder: "group"), directory: local, project: project)
        let store = ResearchCodebookStore(), q = quote("r")
        let saved = try await store.update(place, .pass(.init(entries: [item("晨杯", "r")], names: nil), [q], endMs: 2600))
        XCTAssertEqual(saved.projectMergePending, true); XCTAssertEqual(saved.cards.first?.entries.first?.evidence.original, q.original)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var other = ResearchCodebook(); other.seed("Morning Cup（晨杯）", type: .brand)
        try JSONEncoder().encode(other).write(to: project.appendingPathComponent("codebook.json"))
        let retried = try await store.update(place, .refresh)
        XCTAssertEqual(retried.cards.count, 1); XCTAssertEqual(retried.cards[0].entries.first?.evidence.original, q.original); XCTAssertEqual(retried.projectMergePending, false)
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

    // MARK: - Live topic map

    private func card(_ name: String, _ type: ResearchCardType, pinned: Bool = false,
                      _ mentions: [(session: String, offset: Int, valence: ResearchValence)]) -> ResearchCard {
        let entries = mentions.enumerated().map { index, mention in
            var evidence = quote("\(name)-\(index)", session: mention.session)
            evidence = ResearchQuote(sessionID: evidence.sessionID, turnID: evidence.turnID, group: evidence.group, offsetMs: mention.offset,
                                     original: evidence.original, speaker: evidence.speaker, revealRecorded: false)
            return ResearchEntry(point: "A point.", evidence: evidence, valence: mention.valence, inferredName: nil)
        }
        return ResearchCard(id: UUID(), name: name, aliases: [], type: type, origin: .emerged, pinned: pinned, entries: entries)
    }

    func testTopicMapGroupsBrandsConceptsHypothesesAndLeavesOutPeople() {
        var book = ResearchCodebook()
        book.cards = [
            card("Morning Cup（晨杯）", .brand, [("session1", 1000, .positive), ("session1", 2000, .positive)]),
            card("小禾", .person, [("session1", 3000, .neutral)]),
            card("Side pocket", .concept, [("session1", 4000, .negative)]),
            card("Retail Co", .org, [("session1", 5000, .neutral)]),
            card("Carry beats capacity", .hypothesis, [("session1", 6000, .mixed)]),
            card("Seeded, never mentioned", .concept, []),
        ]
        let map = book.topicMap()
        XCTAssertEqual(map.sections.map(\.group), [.brands, .concepts, .hypotheses])
        XCTAssertEqual(map.sections[0].topics.map(\.name), ["Morning Cup（晨杯）", "Retail Co"], "organisations sit with brands")
        XCTAssertEqual(map.sections[1].topics.map(\.name), ["Side pocket"], "a card with no mention is left out")
        XCTAssertFalse(map.sections.flatMap(\.topics).contains { $0.name == "小禾" }, "people are never shown")
        XCTAssertEqual(map.sections[0].topics[0].mentions, 2)
        XCTAssertEqual(map.total, 4)
        XCTAssertEqual(map.hidden, 0)
        XCTAssertEqual(map.newestID, book.cards[4].id)
    }

    func testTopicMapKeepsCardOrderWhenCountsChangeAndCountsOneSession() {
        var book = ResearchCodebook()
        book.cards = [
            card("Lid", .concept, [("session1", 1000, .neutral)]),
            card("Handle", .concept, [("session1", 2000, .neutral), ("session2", 2500, .neutral)]),
        ]
        XCTAssertEqual(book.topicMap().sections[0].topics.map(\.name), ["Lid", "Handle"])
        book.cards[1].entries += card("Handle", .concept, [("session1", 9000, .neutral), ("session1", 9500, .neutral)]).entries
        XCTAssertEqual(book.topicMap().sections[0].topics.map(\.name), ["Lid", "Handle"], "a chip never moves when its count grows")
        let scoped = book.topicMap(sessionID: "session2")
        XCTAssertEqual(scoped.sections[0].topics.map(\.name), ["Handle"])
        XCTAssertEqual(scoped.sections[0].topics[0].mentions, 1)
    }

    func testTopicMapCapKeepsPinnedAndMostMentionedAndCountsTheRest() {
        var book = ResearchCodebook()
        book.cards = (0 ..< 20).map { index in
            card("Topic \(index)", .concept, pinned: index == 0, Array(repeating: ("session1", index * 100, ResearchValence.neutral), count: index == 0 ? 1 : index + 1))
        }
        let map = book.topicMap()
        XCTAssertEqual(map.shown, ResearchCodebook.topicLimit)
        XCTAssertEqual(map.hidden, 2)
        let names = map.sections.flatMap(\.topics).map(\.name)
        XCTAssertEqual(names.first, "Topic 0", "pinned stays even with one mention")
        XCTAssertFalse(names.contains("Topic 1"))
        XCTAssertFalse(names.contains("Topic 2"))
        XCTAssertEqual(names, names.sorted { Int($0.split(separator: " ")[1])! < Int($1.split(separator: " ")[1])! }, "codebook order")
    }

    func testTopicValenceIsMixedWhenMentionsPullBothWays() {
        XCTAssertEqual(ResearchCodebook.overallValence([.positive, .neutral]), .positive)
        XCTAssertEqual(ResearchCodebook.overallValence([.negative]), .negative)
        XCTAssertEqual(ResearchCodebook.overallValence([.positive, .negative]), .mixed)
        XCTAssertEqual(ResearchCodebook.overallValence([.neutral, .mixed]), .mixed)
        XCTAssertEqual(ResearchCodebook.overallValence([.neutral]), .neutral)
    }
}
