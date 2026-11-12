import RTICore
import XCTest

final class GuideCoreTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("GuideFixtures")
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func guide() throws -> GuideDocument {
        try GuideDocument.parse(fixture("dg-questions.json"))
    }

    private func turn(_ id: String, _ speaker: String = "remote_2", _ startMs: Int = 70050,
                      _ text: String = "我选 A，拿着舒服。") -> GuideTurn
    {
        GuideTurn(id: id, speaker: speaker, startMs: startMs, text: text)
    }

    private let speakers = ["remote_2": GuideSpeaker(participant: "P1", seatCode: "1U"),
                            "remote_7": GuideSpeaker(participant: "Moderator", isModerator: true)]

    private func pass(_ cells: [[String: Any]]) throws -> GuidePass {
        let json: [String: Any] = ["suggestion": NSNull(), "evidence": [], "cells": cells]
        return try JSONDecoder().decode(GuidePass.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func cell(turns: [String] = ["r1"], quotes: [String] = ["r1"], votes: [String] = ["r1"],
                      summary: String = "P1 chose A. The cup is easy to hold.") -> [String: Any]
    {
        ["qid": "S1Q1", "coverage": "Answered", "summary": summary, "turns": turns,
         "quotes": quotes.map { ["turn": $0, "english": "I choose A. It is comfortable to hold."] },
         "votes": votes.map { ["turn": $0, "choice": "A"] }]
    }

    func testWorkbookGuideFixtureIncludesBilingualProbesOptionalFlagsAndPlannedMinutes() throws {
        let guide = try guide()
        XCTAssertEqual(guide.questions.map(\.qid), ["S1Q1", "S1Q2", "S2Q1"])
        XCTAssertEqual(guide.sections.map(\.minutes), [6, 4])
        XCTAssertEqual(guide.questions[0].probes.first?.zh, "是什么影响了你的选择？")
        XCTAssertTrue(guide.questions[0].mustAsk)
        XCTAssertFalse(guide.questions[1].mustAsk)
        let bad = try XCTUnwrap(String(data: fixture("dg-questions.json"), encoding: .utf8))
            .replacingOccurrences(of: "S1Q2", with: "S1Q1")
        XCTAssertThrowsError(try GuideDocument.parse(Data(bad.utf8)))
    }

    func testOverrideRejectsStalePassesBacktrackingAndRepeatedEvidence() throws {
        var cursor = try GuideCursor(guide: guide())
        let originalRevision = cursor.revision
        cursor.select("S1Q2", atMs: 15000)
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("a"), turn("b")], revision: originalRevision))
        XCTAssertFalse(cursor.suggest("S1Q1", evidence: [turn("a"), turn("b")], revision: cursor.revision))
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("old", "self", 5000), turn("c", "self", 16000)], revision: cursor.revision))
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("c", "self", 16000)], revision: cursor.revision))
        XCTAssertTrue(cursor.suggest("S2Q1", evidence: [turn("d", "remote_2", 20000)], revision: cursor.revision))
        XCTAssertEqual(cursor.currentQID, "S2Q1")
        XCTAssertEqual(cursor.acceptedFromMs, 16000)
        cursor.select("S1Q1", atMs: 25000)
        XCTAssertEqual(cursor.currentQID, "S1Q1")
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("d", "remote_2", 20000)], revision: cursor.revision))
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("e", "self", 40000)], revision: cursor.revision))
        XCTAssertFalse(cursor.suggest("S2Q1", evidence: [turn("f", "self", 200_000)], revision: cursor.revision))
    }

    func testGoldenExportRejectsEveryMicSpeakerMarkedModeratorAndOtherGroupTurns() throws {
        var extraction = try GuideExtraction(group: "g1", transcript: "mock-group.txt", guide: guide())
        let all = ["self", "room", "facilitator", "r1", "other-session"]
        let denied = all.filter { $0 != "r1" }
        let result = try pass([cell(turns: denied, quotes: denied, votes: denied, summary: "A moderator spoke."),
                               cell(quotes: all, votes: all)])
        extraction.apply(result, turns: [turn("self", "self"), turn("room", "room_1"), turn("facilitator", "remote_7"),
                                         turn("r1")], speakers: speakers, rosterBase: 3)
        XCTAssertEqual(extraction.fileName, "guide-cells-G1.json")
        let actual = try JSONEncoder().encode(extraction)
        let expected = try fixture(extraction.fileName)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(GuideExtraction.self, from: actual), extraction)
        extraction.reanchor { _ in (83000, "Remote speaker 4") }
        XCTAssertEqual(extraction.cells[0].quotes[0].locator, "00:01:23")
        extraction.reanchor { _ in nil }
        XCTAssertEqual(extraction.cells[0].quotes[0].locator, "00:01:10")
        XCTAssertEqual(extraction.cells[0].quotes[0].verification, "unverified")
        XCTAssertEqual(extraction.cells[0].quotes[0].original, "我选 A，拿着舒服。")
        extraction.remap(speakers: ["remote_2": GuideSpeaker(participant: "Facilitator", isModerator: true)], rosterBase: 3)
        XCTAssertEqual(extraction.cells[0].coverage, "Not covered")
        XCTAssertEqual(extraction.cells[0].quotes, [])
        XCTAssertEqual(extraction.cells[0].summary, "")
        XCTAssertNil(extraction.cells[0].tally)
    }

    func testNoInventedVoteBaseNoDoubleCountingAndNoUnsupportedSummary() throws {
        var extraction = try GuideExtraction(group: "", transcript: "mock-group.txt", guide: guide())
        let respondent = try XCTUnwrap(speakers["remote_2"])
        let aliases = ["remote_2": respondent, "remote_3": respondent]
        let result = try pass([cell(turns: ["r1", "r2", "o"], quotes: ["r1"], votes: ["r1", "r2"], summary: "Wrong group.")])
        extraction.apply(result, turns: [turn("r1"), turn("r2", "remote_3")], speakers: aliases, rosterBase: nil)
        XCTAssertEqual(extraction.fileName, "guide-cells-unassigned.json")
        XCTAssertNil(extraction.cells[0].tally)
        XCTAssertFalse(extraction.cells[0].summary.contains("Wrong group"))
        XCTAssertEqual(extraction.cells[0].coverage, "Lightly covered")
        extraction.remap(speakers: aliases, rosterBase: 2)
        XCTAssertEqual(extraction.cells[0].tally, "1 of 2 chose A")
    }

    func testNamedChoiceMustAppearAsAChoiceAndCannotContradictSameSeatsEarlierVote() throws {
        var extraction = try GuideExtraction(group: "G1", transcript: "mock-group.txt", guide: guide())
        let first = try pass([cell()])
        extraction.apply(first, turns: [turn("r1", "remote_2", 1, "I like the handle.")], speakers: speakers, rosterBase: 3)
        XCTAssertNil(extraction.cells[0].tally)
        let valid = try pass([cell(turns: ["r2"], quotes: [], votes: ["r2"])])
        extraction.apply(valid, turns: [turn("r2", "remote_2", 2, "我选A。")], speakers: speakers, rosterBase: 3)
        XCTAssertEqual(extraction.cells[0].tally, "1 of 3 chose A")
        var conflicting = cell(turns: ["r3"], quotes: [], votes: [])
        conflicting["votes"] = [["turn": "r3", "choice": "B"]]
        try extraction.apply(pass([conflicting]), turns: [turn("r3", "remote_2", 3, "B")], speakers: speakers, rosterBase: 3)
        XCTAssertNil(extraction.cells[0].tally)
    }

    func testSummaryUsesWholeSentencesFromEarlyAndLateRevisits() throws {
        var extraction = try GuideExtraction(group: "G1", transcript: "mock-group.txt", guide: guide())
        let summaries = ["The cup sits on the desk. The rim feels wide.",
                         "杯子很轻。拿着很舒服。", "The lid fits. It stays shut."]
        for (index, summary) in summaries.enumerated() {
            let id = String(index)
            try extraction.apply(pass([cell(turns: [id], quotes: [], votes: [], summary: summary)]),
                                 turns: [turn(id)], speakers: speakers, rosterBase: nil)
        }
        XCTAssertEqual(extraction.cells[0].summary, "The cup sits on the desk. The rim feels wide. The lid fits. It stays shut.")
        let chinese = "带起来很方便。"
        try extraction.apply(pass([cell(turns: ["last"], quotes: [], votes: [], summary: chinese)]),
                             turns: [turn("last")], speakers: speakers, rosterBase: nil)
        XCTAssertTrue(extraction.cells[0].summary.hasSuffix(chinese))
    }

    func testVeryLongUnpunctuatedSummariesFallBackToAnIntactQuote() throws {
        for text in [String(repeating: "a very long answer ", count: 60), String(repeating: "这是没有标点的原话", count: 90)] {
            var extraction = try GuideExtraction(group: "G1", transcript: "mock-group.txt", guide: guide())
            let result = try pass([cell(votes: [], summary: text)])
            extraction.apply(result, turns: [turn("r1")], speakers: speakers, rosterBase: nil)
            XCTAssertEqual(extraction.cells[0].summary, "P1: 我选 A，拿着舒服。")
            var longQuote = try GuideExtraction(group: "G1", transcript: "mock-group.txt", guide: guide())
            longQuote.apply(result, turns: [turn("r1", "remote_2", 1234, text)], speakers: speakers, rosterBase: nil)
            XCTAssertLessThan(longQuote.cells[0].summary.unicodeScalars.count, 480)
            XCTAssertEqual(longQuote.cells[0].quotes.first?.original, text)
        }
    }

    func testManualRoutingSplitsEvidenceAndDropsMixedQuestionSummary() throws {
        let model = try pass([cell(turns: ["a", "b"], quotes: ["a", "b", "invented"], votes: ["b", "invented"])])
        let routed = model.routing { $0 == "b" ? "S2Q1" : nil }
        XCTAssertEqual(routed.cells.map(\.qid), ["S1Q1", "S2Q1"])
        XCTAssertEqual(routed.cells.map(\.summary), ["", ""])
        XCTAssertEqual(routed.cells[0].quotes.map(\.turn), ["a"])
        XCTAssertEqual(routed.cells[1].votes.map(\.turn), ["b"])
        XCTAssertEqual(model.routing { _ in nil }.cells.first?.summary, model.cells.first?.summary)
    }

    func testTrackerOrdersAllEvidenceAndCanUndoModeratorCorrection() throws {
        let ids = Array(1...6).map(String.init)
        let first = try pass([cell(turns: ids, quotes: ids.reversed().map { $0 }, votes: [])])
        var result = try GuideExtraction(group: "G2", transcript: "fixture.md", guide: guide())
        let turns = ids.enumerated().map { index, id in turn(id, "remote_2", index * 1000, "杯子 \(id)") }
        result.apply(first, turns: turns, speakers: speakers, rosterBase: nil)
        XCTAssertEqual(result.cells[0].orderedQuotes.map(\.turnID), ids)
        XCTAssertEqual(result.cells[0].quotes.count, 4)
        result.remap(speakers: ["remote_2": GuideSpeaker(participant: "Moderator", isModerator: true)], rosterBase: nil)
        XCTAssertTrue(result.cells[0].orderedQuotes.isEmpty)
        result = try JSONDecoder().decode(GuideExtraction.self, from: JSONEncoder().encode(result))
        result.remap(speakers: speakers, rosterBase: nil)
        XCTAssertEqual(result.cells[0].orderedQuotes.map(\.original), turns.map(\.text))
        result.reanchor { ($0.liveStartMs + 900, "Remote speaker 3") }
        result.refile(speakers: speakers, rosterBase: nil) { $0 >= 2500 ? "S1Q2" : "S1Q1" }
        XCTAssertEqual(result.cells[0].orderedQuotes.map(\.turnID), ["1", "2"])
        XCTAssertEqual(result.cells[1].orderedQuotes.map(\.turnID), ["3", "4", "5", "6"])
        XCTAssertEqual(result.cells[1].orderedQuotes.first?.speakerLabel, "P1")
    }

    func testLoopHeadersAndUncoveredStatuses() throws {
        let data = Data(#"{"title":"Food","sections":[{"id":"S1","title":"Shopping","questions":[{"qid":"S1Q1","part":"Drink one","en":"[Choice] Which?","zh":"选哪一种？","probes":[]},{"qid":"S1Q2","part":"Drink two","en":"[Choice] Which?","zh":"选哪一种？","probes":[]}]}]}"#.utf8)
        let guide = try GuideDocument.parse(data)
        XCTAssertEqual(guide.header(for: guide.questions[1], in: guide.sections[0]), "Drink two · Choice")
        XCTAssertNil(guide.resolveMarker("[Choice] Which?"))
        XCTAssertEqual(guide.resolveMarker("S1", answered: ["S1Q1"]), "S1Q2")
        let dataSet = GuideExtraction(group: "", transcript: "", guide: guide)
        XCTAssertEqual(dataSet.cells[0].displayCoverage(passed: true), "Skipped")
        XCTAssertEqual(dataSet.cells[1].displayCoverage(passed: false), "Pending")
    }

    func testBoundedQuotesAndDeniedOverrideEvidence() throws {
        var extraction = try GuideExtraction(group: "G2", transcript: "mock-group.txt", guide: guide())
        let ids = ["1", "2", "3", "4", "5", "6"]
        let result = try pass([cell(turns: ids, quotes: ids, votes: [], summary: "Unaccepted first turn.")])
        extraction.apply(result, turns: ids.map { turn($0) }, speakers: speakers, rosterBase: nil) { _, turn in
            turn != "1"
        }
        XCTAssertEqual(extraction.cells[0].quotes.map(\.turnID), ["2", "3", "4", "5"])
        XCTAssertEqual(extraction.cells[0].coverage, "Lightly covered")
        XCTAssertFalse(extraction.cells[0].summary.contains("Unaccepted"))
    }
}
